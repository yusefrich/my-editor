#!/usr/bin/env node
// Static index of a TypeScript BFF: which HTTP routes (TSOA, NestJS or Express) reach which
// upstream operations (generated OpenAPI SDK functions + their spec entries, Prisma models,
// AWS SDK commands, npm client packages, fetch), through however many hops sit in between.
//
// Uses the project's own `typescript` so call targets are resolved by the type checker
// (`this.fooService.bar()`, path aliases, re-exports) instead of guessed by regex.
//
// Usage:
//   node indexer.cjs --detect <repo-root>             -> suggested config JSON on stdout
//   node indexer.cjs <worktree-root> '<project-json>' -> index JSON on stdout
//
// All paths inside a project config are relative to `<worktree-root>/<project.dir>`, and so are
// all paths in the index output.
"use strict";

const fs = require("fs");
const path = require("path");

const HTTP = ["get", "post", "put", "patch", "delete", "head", "options"];
const ROUTE_VERBS = [...HTTP, "all"];
const SKIP_DIRS = new Set(["node_modules", ".git", "dist", "build", "coverage", ".next", ".turbo", "out"]);

const posix = (p) => p.split(path.sep).join("/");
const readJson = (f) => {
  try {
    return JSON.parse(fs.readFileSync(f, "utf8"));
  } catch (_) {
    return null;
  }
};
const joinRoute = (...parts) =>
  "/" +
  parts
    .filter(Boolean)
    .join("/")
    .replace(/\/{2,}/g, "/")
    .replace(/^\/|\/$/g, "");

// Minimal glob: `**` any depth, `*` one segment, `?` one char. A pattern with no glob chars
// matches that file or anything under that directory.
function globToRegex(glob) {
  if (!/[*?]/.test(glob)) {
    const lit = glob.replace(/\/$/, "").replace(/[.+^${}()|[\]\\]/g, "\\$&");
    return new RegExp(`^${lit}(/|$)`);
  }
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") {
      re += glob[i + 2] === "/" ? "(?:.*/)?" : ".*";
      i += glob[i + 2] === "/" ? 2 : 1;
    } else if (c === "*") re += "[^/]*";
    else if (c === "?") re += "[^/]";
    else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}

// Walk a tree, skipping dependency/build dirs, hidden dirs, nested git checkouts (worktrees kept
// inside the repo) and, with `ownPackage`, nested packages (dirs with their own package.json).
function walk(dir, onFile, opts = {}, depth = 0) {
  if (depth > 12) return;
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name) || e.name.startsWith(".")) continue;
      if (fs.existsSync(path.join(p, ".git"))) continue;
      if (opts.ownPackage && fs.existsSync(path.join(p, "package.json"))) continue;
      walk(p, onFile, opts, depth + 1);
    } else if (e.isFile()) onFile(p, e.name);
  }
}

// ===========================================================================
// --detect: suggest a project config from what the repo contains
// ===========================================================================
function deps(pkg) {
  return Object.assign({}, pkg && pkg.dependencies, pkg && pkg.devDependencies);
}

// Shared libraries named *-client / *-sdk that are not service clients.
const NOT_SERVICE_CLIENTS = /^(@prisma\/client|@aws-sdk\/|@smithy\/|@hey-api\/|@apollo\/client|@tanstack\/|@redis\/client|redis-client|@elastic\/|@opensearch-project\/|@grpc\/|@types\/)/;

const normName = (s) =>
  s
    .toLowerCase()
    .replace(/\.(json|ya?ml)$/, "")
    .replace(/(-|_)?(openapi|swagger|spec|api)$/g, "")
    .replace(/(-|_)?(openapi|swagger|spec|api)$/g, "")
    .replace(/[^a-z0-9]/g, "");

function detectProject(repoRoot, dir) {
  const pkg = readJson(path.join(dir, "package.json"));
  const d = deps(pkg);
  const frameworks = [];
  if (d.tsoa || d["@tsoa/runtime"]) frameworks.push("tsoa");
  if (d["@nestjs/common"]) frameworks.push("nest");
  if (d.express) frameworks.push("express");

  const rel = (f) => posix(path.relative(dir, f)) || ".";
  const source = fs.existsSync(path.join(dir, "src")) ? ["src"] : ["."];
  const exclude = [];
  let basePath = "";
  let ownSpec = null;

  const tsoa = readJson(path.join(dir, "tsoa.json"));
  if (tsoa) {
    basePath = (tsoa.routes && tsoa.routes.basePath) || (tsoa.spec && tsoa.spec.basePath) || "";
    if (tsoa.spec && tsoa.spec.outputDirectory) ownSpec = posix(path.join(tsoa.spec.outputDirectory, "swagger.json"));
    if (tsoa.routes && tsoa.routes.routesDir) exclude.push(posix(path.normalize(tsoa.routes.routesDir)));
  }

  const sdkFiles = [];
  const specFiles = [];
  const prismaSchemas = [];
  walk(dir, (f, name) => {
    if (name === "schema.prisma") prismaSchemas.push(f);
    else if (/\.(ts|js)$/.test(name) && !/\.d\.ts$/.test(name)) {
      const isGen = /\.gen\.ts$/.test(name) || /^sdk\.(ts|js)$/.test(name);
      if (!isGen && !(frameworks.includes("nest") && !basePath)) return;
      const text = fs.readFileSync(f, "utf8");
      if (isGen && /\.(get|post|put|patch|delete|head|options)\s*(<[^>]*>)?\s*\(\s*\{[\s\S]{0,400}?\burl\s*:\s*['"`]\//.test(text))
        sdkFiles.push(f);
      const prefix = text.match(/setGlobalPrefix\(\s*['"`]([^'"`]+)['"`]/);
      if (prefix && !basePath) basePath = prefix[1];
    } else if (/\.json$/.test(name) && !/^(package(-lock)?|tsconfig.*|tsoa)\.json$/.test(name)) {
      const head = fs.readFileSync(f, "utf8").slice(0, 2000);
      if (/^\s*\{[\s\S]*?"(openapi|swagger)"\s*:/.test(head)) specFiles.push(f);
    }
  }, { ownPackage: true });

  // Generated code lives somewhere under a `generated` dir most of the time; keep it out of the
  // call graph (the SDK files are read on their own).
  for (const s of sdkFiles) {
    const m = rel(s).match(/^(.*?\/generated)(\/|$)/);
    if (m && !exclude.includes(m[1])) exclude.push(m[1]);
  }

  let prisma = null;
  for (const schema of prismaSchemas) {
    const out = fs.readFileSync(schema, "utf8").match(/generator\s+\w+\s*\{[^}]*?\boutput\s*=\s*"([^"]+)"/);
    if (out) {
      prisma = rel(path.resolve(path.dirname(schema), out[1]));
      break;
    }
  }
  if (!prisma && d["@prisma/client"]) prisma = "node_modules/.prisma/client";
  if (prisma && !prisma.startsWith("node_modules") && !exclude.some((e) => prisma.startsWith(e))) exclude.push(prisma);
  // Drop entries already covered by a shorter prefix (`src/generated/tsoa` under `src/generated`).
  const dirs = exclude.filter((e, i) => !exclude.some((o, j) => j !== i && e.startsWith(o + "/")));
  exclude.length = 0;
  exclude.push(...new Set(dirs), "**/*.test.ts", "**/*.spec.ts", "**/__tests__/**");

  const ownSpecAbs = ownSpec && path.join(dir, ownSpec);
  const upstreamSpecs = specFiles.filter((f) => f !== ownSpecAbs);
  const sdk = sdkFiles.map((f) => {
    const parent = path.basename(path.dirname(f));
    const api = parent.replace(/-api$/, "");
    const key = normName(parent);
    let spec =
      upstreamSpecs.find((s) => normName(path.basename(s)) === key) ||
      upstreamSpecs.find((s) => {
        const n = normName(path.basename(s));
        return n && key && (n.includes(key) || key.includes(n));
      });
    if (!spec && sdkFiles.length === 1 && upstreamSpecs.length === 1) spec = upstreamSpecs[0];
    return { file: rel(f), api, spec: spec ? rel(spec) : null };
  });

  const clientPackages = Object.keys(d)
    .filter((n) => /-(client|sdk)$/.test(n) && !NOT_SERVICE_CLIENTS.test(n))
    .sort();

  const watch = new Set([...source, "tsconfig.json"]);
  if (tsoa) watch.add("tsoa.json");
  for (const s of upstreamSpecs) {
    const r = rel(path.dirname(s));
    if (!source.some((src) => src === "." || r === src || r.startsWith(src + "/"))) watch.add(r);
  }

  return {
    dir: posix(path.relative(repoRoot, dir)) || ".",
    name: (pkg && pkg.name) || path.basename(dir),
    tsconfig: "tsconfig.json",
    frameworks,
    basePath,
    source,
    exclude,
    sdk,
    ownSpec,
    prisma,
    clientPackages,
    aws: Object.keys(d).some((n) => n.startsWith("@aws-sdk/")),
    fetch: true,
    watch: [...watch],
    watchSkip: prisma && !prisma.startsWith("node_modules") ? [prisma] : [],
  };
}

function detect(repoRoot) {
  const projects = [];
  walk(repoRoot, (f, name) => {
    if (name !== "tsconfig.json") return;
    const dir = path.dirname(f);
    const d = deps(readJson(path.join(dir, "package.json")));
    if (d.tsoa || d["@tsoa/runtime"] || d["@nestjs/common"] || d.express) projects.push(detectProject(repoRoot, dir));
  });
  if (projects.length === 0 && fs.existsSync(path.join(repoRoot, "tsconfig.json"))) projects.push(detectProject(repoRoot, repoRoot));
  return { projects };
}

if (process.argv[2] === "--detect") {
  process.stdout.write(JSON.stringify(detect(path.resolve(process.argv[3] || process.cwd()))));
  process.exit(0);
}

// ===========================================================================
// Index
// ===========================================================================
const worktree = path.resolve(process.argv[2] || process.cwd());
const project = JSON.parse(process.argv[3] || "{}");
const root = path.resolve(worktree, project.dir || ".");
const frameworks = new Set(project.frameworks || ["tsoa", "nest", "express"]);

// The project's own typescript; worktrees without node_modules fall back to NODE_PATH
// (the nvim side points it at the main checkout).
let ts;
try {
  ts = require(require.resolve("typescript", { paths: [root] }));
} catch (_) {
  ts = require("typescript");
}

const rel = (f) => posix(path.relative(root, f));
const lineOf = (sf, node) => sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;
const colOf = (sf, node) => sf.getLineAndCharacterOfPosition(node.getStart(sf)).character;
const abs = (p) => path.join(root, p);

// ---------------------------------------------------------------------------
// Program
// ---------------------------------------------------------------------------
const cfg = ts.readConfigFile(abs(project.tsconfig || "tsconfig.json"), ts.sys.readFile);
const parsed = ts.parseJsonConfigFileContent(cfg.config, ts.sys, root);
const program = ts.createProgram(parsed.fileNames, { ...parsed.options, noEmit: true });
const checker = program.getTypeChecker();

const basePath = project.basePath || "";
const sourceRes = (project.source || ["src"]).map((s) => (s === "." ? /^/ : globToRegex(s)));
const excludeRes = (project.exclude || []).map(globToRegex);
const PRISMA = project.prisma ? abs(project.prisma) + path.sep : null;
const clientRes = (project.clientPackages || []).map(globToRegex);

const isOwnSource = (f) => {
  const r = rel(f);
  if (r.startsWith("..") || r.includes("node_modules/") || /\.d\.ts$/.test(r)) return false;
  return sourceRes.some((re) => re.test(r)) && !excludeRes.some((re) => re.test(r));
};

// ---------------------------------------------------------------------------
// OpenAPI specs: line of every `paths.<url>.<method>` key. Specs are prettier-formatted JSON,
// so a line scan keyed on indentation is exact enough and keeps line numbers (JSON.parse doesn't).
// ---------------------------------------------------------------------------
function specLines(file) {
  const out = {};
  let pathsIndent = -1;
  let cur = null;
  let curIndent = -1;
  let childIndent = -1;
  const lines = fs.readFileSync(file, "utf8").split("\n");
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(\s*)"([^"]+)"\s*:\s*\{/);
    if (!m) continue;
    const ind = m[1].length;
    const key = m[2];
    if (pathsIndent < 0) {
      if (key === "paths") pathsIndent = ind;
      continue;
    }
    if (ind <= pathsIndent) break; // left the `paths` object
    if (key.startsWith("/") && (cur === null || ind <= curIndent)) {
      cur = key;
      curIndent = ind;
      childIndent = -1;
      continue;
    }
    if (cur === null) continue;
    if (childIndent < 0) childIndent = ind;
    if (ind === childIndent && HTTP.includes(key.toLowerCase())) {
      out[`${key.toLowerCase()} ${cur}`] = i + 1;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Upstream operations, read from each generated SDK file
// ---------------------------------------------------------------------------
const ops = {}; // opId -> op
const opByDecl = new Map(); // "<abs file>#<name>" -> opId
const sdkFiles = new Set();
const specs = {}; // rel spec file -> { "<method> <path>": line }

function findHttpCall(node) {
  let found = null;
  (function visit(n) {
    if (found) return;
    if (
      ts.isCallExpression(n) &&
      ts.isPropertyAccessExpression(n.expression) &&
      HTTP.includes(n.expression.name.text) &&
      n.arguments[0] &&
      ts.isObjectLiteralExpression(n.arguments[0])
    ) {
      const urlProp = n.arguments[0].properties.find(
        (p) => ts.isPropertyAssignment(p) && p.name && p.name.getText() === "url",
      );
      if (urlProp && ts.isStringLiteralLike(urlProp.initializer)) {
        found = { method: n.expression.name.text, url: urlProp.initializer.text };
        return;
      }
    }
    ts.forEachChild(n, visit);
  })(node);
  return found;
}

for (const entry of project.sdk || []) {
  const sdkFile = abs(entry.file);
  const sf = program.getSourceFile(sdkFile);
  if (!sf) continue;
  sdkFiles.add(sf.fileName);
  const api = entry.api || path.basename(path.dirname(sdkFile)).replace(/-api$/, "");
  const specFile = entry.spec && fs.existsSync(abs(entry.spec)) ? abs(entry.spec) : null;
  const specMap = specFile ? specLines(specFile) : {};
  if (specFile) specs[rel(specFile)] = specMap;
  for (const st of sf.statements) {
    if (!ts.isVariableStatement(st) && !ts.isFunctionDeclaration(st)) continue;
    const decls = ts.isVariableStatement(st)
      ? st.declarationList.declarations.map((d) => ({ name: d.name, body: d.initializer, node: d }))
      : [{ name: st.name, body: st.body, node: st }];
    for (const d of decls) {
      if (!d.name || !ts.isIdentifier(d.name) || !d.body) continue;
      const call = findHttpCall(d.body);
      if (!call) continue;
      const id = `${api}:${d.name.text}`;
      const specLine = specMap[`${call.method} ${call.url}`];
      ops[id] = {
        id,
        api,
        fn: d.name.text,
        method: call.method.toUpperCase(),
        url: call.url,
        sdk: { file: rel(sdkFile), line: lineOf(sf, d.node) },
        spec: specFile && specLine ? { file: rel(specFile), line: specLine } : null,
      };
      opByDecl.set(`${sf.fileName}#${d.name.text}`, id);
    }
  }
}

// ---------------------------------------------------------------------------
// Call graph over hand-written source
// ---------------------------------------------------------------------------
const nodes = {}; // nodeId -> { id, name, file, line }
const edges = {}; // nodeId -> Set<nodeId>
const direct = {}; // nodeId -> Set<opId>
const callsites = [];

function isFunctionLike(n) {
  return n && (ts.isArrowFunction(n) || ts.isFunctionExpression(n));
}

function declName(decl) {
  const own = decl.name && decl.name.getText ? decl.name.getText() : "<anonymous>";
  const cls = decl.parent && ts.isClassLike(decl.parent) && decl.parent.name ? decl.parent.name.text : null;
  return cls ? `${cls}.${own}` : own;
}

// Only named callables become graph nodes; anonymous callbacks fold into their owner
// (except inline Express handlers, which get a synthetic node of their own).
function asCallable(n) {
  if (ts.isMethodDeclaration(n) || ts.isFunctionDeclaration(n)) return n.body ? n : null;
  if ((ts.isVariableDeclaration(n) || ts.isPropertyDeclaration(n) || ts.isPropertyAssignment(n)) && isFunctionLike(n.initializer))
    return n;
  return null;
}

function nodeIdOf(decl) {
  const sf = decl.getSourceFile();
  return `${rel(sf.fileName)}:${lineOf(sf, decl.name || decl)}:${declName(decl)}`;
}

function ensureNode(decl) {
  const id = nodeIdOf(decl);
  if (!nodes[id]) {
    const sf = decl.getSourceFile();
    nodes[id] = { id, name: declName(decl), file: rel(sf.fileName), line: lineOf(sf, decl.name || decl) };
  }
  return id;
}

function syntheticNode(sf, at, name) {
  const id = `${rel(sf.fileName)}:${lineOf(sf, at)}:${name}`;
  nodes[id] ||= { id, name, file: rel(sf.fileName), line: lineOf(sf, at) };
  return id;
}

function resolve(expr) {
  const target = ts.isPropertyAccessExpression(expr) ? expr.name : expr;
  let sym = checker.getSymbolAtLocation(target);
  if (!sym) return null;
  if (sym.flags & ts.SymbolFlags.Alias) sym = checker.getAliasedSymbol(sym);
  return (sym.declarations && sym.declarations[0]) || null;
}

// The `{ ... }` a command was built with: `send(new X({...}))` or `const c = new X({...}); send(c)`.
function commandInput(arg) {
  if (ts.isIdentifier(arg)) {
    const decl = resolve(arg);
    if (decl && ts.isVariableDeclaration(decl) && decl.initializer) arg = decl.initializer;
  }
  if (ts.isNewExpression(arg) && arg.arguments && ts.isObjectLiteralExpression(arg.arguments[0])) return arg.arguments[0];
  return null;
}

// Bucket names as far as the repo states them. A literal `Bucket: "x"` wins; otherwise the
// value usually comes from a config constant (`const { bucket } = settings`), so collect the
// string literals given to that same property name in this file and the files it imports.
function awsBuckets(cmdArg, sf) {
  const input = commandInput(cmdArg);
  const prop =
    input &&
    input.properties.find((p) => (ts.isPropertyAssignment(p) || ts.isShorthandPropertyAssignment(p)) && p.name.getText() === "Bucket");
  if (!prop) return [];
  const init = ts.isPropertyAssignment(prop) ? prop.initializer : prop.name;
  if (ts.isStringLiteralLike(init)) return [init.text];

  let key = null;
  if (ts.isPropertyAccessExpression(init)) key = init.name.text;
  else if (ts.isIdentifier(init)) {
    const decl = resolve(init);
    key = decl && ts.isBindingElement(decl) ? (decl.propertyName || decl.name).getText() : init.text;
  }
  if (!key) return [];

  const files = [sf];
  for (const st of sf.statements) {
    if (!ts.isImportDeclaration(st)) continue;
    const mod = checker.getSymbolAtLocation(st.moduleSpecifier);
    const target = mod && mod.valueDeclaration;
    if (target && ts.isSourceFile(target) && isOwnSource(target.fileName)) files.push(target);
  }
  const found = new Set();
  for (const f of files) {
    (function visit(n) {
      if (ts.isPropertyAssignment(n) && n.name.getText() === key && ts.isStringLiteralLike(n.initializer)) found.add(n.initializer.text);
      ts.forEachChild(n, visit);
    })(f);
  }
  return [...found];
}

function addDirect(ownerId, opId, expr, sf) {
  (direct[ownerId] ||= new Set()).add(opId);
  callsites.push({ file: rel(sf.fileName), line: lineOf(sf, expr), col: colOf(sf, expr), op: opId, owner: ownerId });
}

// Package name of the last `node_modules/<pkg>` in a path.
function packageOf(file) {
  const all = [...posix(file).matchAll(/node_modules\/((?:@[^/]+\/)?[^/]+)/g)];
  return all.length ? all[all.length - 1][1] : null;
}

function link(ownerId, expr, sf) {
  const decl = resolve(expr);
  if (!decl) return;
  const file = decl.getSourceFile().fileName;
  if (sdkFiles.has(file) && decl.name) {
    const opId = opByDecl.get(`${file}#${decl.name.getText()}`);
    if (opId) addDirect(ownerId, opId, expr, sf);
    return;
  }
  // `<anything>.<model>.<op>()` whose op is declared by the Prisma client: a DB "upstream".
  if (PRISMA && file.startsWith(PRISMA) && ts.isPropertyAccessExpression(expr) && ts.isPropertyAccessExpression(expr.expression)) {
    const model = expr.expression.name.text;
    const op = expr.name.text;
    if (model.startsWith("$")) return; // $transaction, $queryRaw… — the inner calls carry the model
    const opId = `db:${model}.${op}`;
    ops[opId] ||= { id: opId, api: "db", fn: `${model}.${op}`, method: op, url: model, sdk: null, spec: null };
    addDirect(ownerId, opId, expr, sf);
    return;
  }
  // AWS SDK v3: `client.send(command)`. Purely static — nothing talks to AWS.
  if (project.aws !== false && /node_modules[\\/](@smithy|@aws-sdk)[\\/]/.test(file) && ts.isPropertyAccessExpression(expr) && expr.name.text === "send") {
    const call = expr.parent;
    const cmdArg = ts.isCallExpression(call) ? call.arguments[0] : null;
    if (!cmdArg) return;
    const command = (checker.getTypeAtLocation(cmdArg).getSymbol() || {}).name || "Command";
    const clientName = (checker.getTypeAtLocation(expr.expression).getSymbol() || {}).name || "AwsClient";
    const service = clientName.replace(/Client$/, "").toLowerCase() || "aws";
    const buckets = awsBuckets(cmdArg, sf);
    const url = buckets.length ? buckets.join(", ") : "?";
    const opId = `aws:${service}:${command}:${url}`;
    ops[opId] ||= { id: opId, api: service, fn: command, method: command.replace(/Command$/, ""), url, sdk: null, spec: null };
    addDirect(ownerId, opId, expr, sf);
    return;
  }
  // Pre-built service clients shipped as npm packages (`clientPackages` in the config).
  const pkg = clientRes.length && file.includes("node_modules") ? packageOf(file) : null;
  if (pkg && decl.name && clientRes.some((re) => re.test(pkg))) {
    const fn = decl.name.getText();
    const opId = `pkg:${pkg}:${fn}`;
    const api = pkg.replace(/^@[^/]+\//, "").replace(/-(client|sdk)$/, "");
    ops[opId] ||= { id: opId, api, fn, method: "CALL", url: fn, sdk: null, spec: null };
    addDirect(ownerId, opId, expr, sf);
    return;
  }
  // Hand-rolled HTTP (`fetch(url, …)` from node-fetch or the global).
  if (project.fetch !== false && ts.isIdentifier(expr) && expr.text === "fetch" && ts.isCallExpression(expr.parent) && expr.parent.expression === expr) {
    const arg = expr.parent.arguments[0];
    const url = arg ? arg.getText(sf).replace(/\s+/g, " ").slice(0, 80) : "?";
    const opId = `http:${url}`;
    ops[opId] ||= { id: opId, api: "fetch", fn: "fetch", method: "HTTP", url, sdk: null, spec: null };
    addDirect(ownerId, opId, expr, sf);
    return;
  }
  if (!isOwnSource(file)) return;
  const callable = asCallable(decl);
  if (!callable) return;
  const to = ensureNode(callable);
  if (to !== ownerId) (edges[ownerId] ||= new Set()).add(to);
}

const isRefExpr = (e) => ts.isIdentifier(e) || ts.isPropertyAccessExpression(e);

// ---------------------------------------------------------------------------
// Express: `<router>.<verb>("/path", ...handlers)` and `<parent>.use("/prefix", router)`
// ---------------------------------------------------------------------------
const expressRoutes = []; // { method, sub, keys, receiver, handler, node, file, line }
const mounts = []; // { parent: [keys], prefix, child: key }
const inlineOwners = new Map(); // function node -> synthetic node id

const isExpressDecl = (decl) =>
  /node_modules[\\/](@types[\\/])?(express|express-serve-static-core|router)[\\/]/.test(decl.getSourceFile().fileName);

function literalPath(arg) {
  if (!arg) return null;
  if (ts.isStringLiteralLike(arg)) return arg.text;
  const t = checker.getTypeAtLocation(arg);
  return t && t.isStringLiteral && t.isStringLiteral() ? t.value : null;
}

function declKey(decl) {
  const sf = decl.getSourceFile();
  return `${sf.fileName}:${decl.pos}`;
}

// Identity of a router expression: its declaration, plus the function that creates and returns
// it (so `app.use("/x", makeRouter())` matches the routes registered inside `makeRouter`).
function routerKeys(expr) {
  const decl = resolve(expr);
  if (!decl) return [`text:${expr.getText()}`];
  const keys = [declKey(decl)];
  for (let p = decl.parent; p; p = p.parent) {
    if (ts.isFunctionDeclaration(p) || isFunctionLike(p) || ts.isMethodDeclaration(p)) {
      const named = isFunctionLike(p) && p.parent && ts.isVariableDeclaration(p.parent) ? p.parent : p;
      keys.push(declKey(named));
      break;
    }
  }
  return keys;
}

function mountChildKey(arg) {
  if (isRefExpr(arg)) {
    const decl = resolve(arg);
    return decl ? declKey(decl) : `text:${arg.getText()}`;
  }
  if (ts.isCallExpression(arg) && isRefExpr(arg.expression)) {
    const decl = resolve(arg.expression);
    return decl ? declKey(decl) : null;
  }
  return null;
}

// `asyncHandler(fn)` / `wrap(async (req, res) => …)`: the innermost handler.
function unwrapHandler(arg) {
  while (arg && ts.isCallExpression(arg) && arg.arguments.length) arg = arg.arguments[arg.arguments.length - 1];
  return arg;
}

function expressCall(n, sf) {
  if (!frameworks.has("express") || !ts.isPropertyAccessExpression(n.expression)) return;
  const verb = n.expression.name.text;
  if (verb !== "use" && !ROUTE_VERBS.includes(verb)) return;
  const decl = resolve(n.expression);
  const first = n.arguments[0];
  const sub = literalPath(first);
  // Without node_modules (a fresh worktree) the express types do not resolve: fall back to
  // the shape `x.get("/path", handler)`.
  if (decl ? !isExpressDecl(decl) : !(sub && sub.startsWith("/"))) return;
  const receiver = n.expression.expression;

  if (verb === "use") {
    const rest = sub !== null ? n.arguments.slice(1) : n.arguments;
    for (const a of rest) {
      const child = mountChildKey(a);
      if (child) mounts.push({ parent: routerKeys(receiver), prefix: sub || "", child });
    }
    return;
  }
  if (n.arguments.length < 2 || sub === null) return; // `app.get("env")` is a settings getter
  const handler = unwrapHandler(n.arguments[n.arguments.length - 1]);
  const method = verb.toUpperCase();
  let node = null;
  let handlerName = "inline";
  if (handler && isFunctionLike(handler)) {
    node = syntheticNode(sf, handler, `${method} ${sub}`);
    inlineOwners.set(handler, node);
  } else if (handler && isRefExpr(handler)) {
    const hd = resolve(handler);
    const callable = hd && isOwnSource(hd.getSourceFile().fileName) && asCallable(hd);
    if (callable) {
      node = ensureNode(callable);
      handlerName = declName(callable);
    } else handlerName = handler.getText();
  }
  node ||= syntheticNode(sf, n, `${method} ${sub}`);
  expressRoutes.push({
    method,
    sub,
    keys: routerKeys(receiver),
    receiver: receiver.getText(sf).replace(/\s+/g, ""),
    handler: handlerName,
    node,
    file: rel(sf.fileName),
    line: lineOf(sf, n),
  });
}

for (const sf of program.getSourceFiles()) {
  if (!isOwnSource(sf.fileName)) continue;
  (function visit(n, owner) {
    const callable = asCallable(n);
    if (callable) owner = ensureNode(callable);
    if (inlineOwners.has(n)) owner = inlineOwners.get(n);
    if (ts.isCallExpression(n)) {
      expressCall(n, sf);
      if (owner) {
        if (isRefExpr(n.expression)) link(owner, n.expression, sf);
        // Functions handed over as callbacks (`items.map(toThing)`, `withRetry(rGetX)`).
        for (const a of n.arguments) if (isRefExpr(a)) link(owner, a, sf);
      }
    }
    ts.forEachChild(n, (c) => visit(c, owner));
  })(sf, null);
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
function decoratorsOf(n) {
  const ds = ts.canHaveDecorators && ts.canHaveDecorators(n) ? ts.getDecorators(n) : n.decorators;
  return (ds || [])
    .filter((d) => ts.isCallExpression(d.expression) && ts.isIdentifier(d.expression.expression))
    .map((d) => ({ name: d.expression.expression.text, args: d.expression.arguments }));
}

function stringArg(arg) {
  if (!arg) return "";
  if (ts.isObjectLiteralExpression(arg)) {
    // Nest: @Controller({ path: "x", version: "1" })
    const p = arg.properties.find((p) => ts.isPropertyAssignment(p) && p.name.getText() === "path");
    return p ? stringArg(p.initializer) : "";
  }
  if (ts.isArrayLiteralExpression(arg)) return stringArg(arg.elements[0]);
  return literalPath(arg) || "";
}

const CLASS_DECORATORS = new Set([...(frameworks.has("tsoa") ? ["Route"] : []), ...(frameworks.has("nest") ? ["Controller"] : [])]);

const routes = [];
const addRoute = (r) => routes.push({ idx: routes.length + 1, upstream: [], ...r });

if (CLASS_DECORATORS.size) {
  for (const sf of program.getSourceFiles()) {
    if (!isOwnSource(sf.fileName)) continue;
    for (const st of sf.statements) {
      if (!ts.isClassDeclaration(st) || !st.name) continue;
      const routeDec = decoratorsOf(st).find((d) => CLASS_DECORATORS.has(d.name));
      if (!routeDec) continue;
      const base = stringArg(routeDec.args[0]);
      for (const m of st.members) {
        if (!ts.isMethodDeclaration(m) || !m.body) continue;
        const verb = decoratorsOf(m).find((d) => ROUTE_VERBS.includes(d.name.toLowerCase()));
        if (!verb) continue;
        const sub = stringArg(verb.args[0]);
        addRoute({
          controller: st.name.text,
          handler: m.name.getText(),
          method: verb.name.toUpperCase(),
          path: joinRoute(basePath, base, sub),
          specPath: joinRoute(base, sub), // as it appears in a tsoa swagger.json
          file: rel(sf.fileName),
          line: lineOf(sf, m.name),
          node: ensureNode(m),
        });
      }
    }
  }
}

// Every prefix a router is reachable under, through nested `use` mounts.
function prefixesOf(keys, seen = new Set()) {
  const out = [];
  for (const m of mounts) {
    if (!keys.includes(m.child) || seen.has(m)) continue;
    seen.add(m);
    const parents = prefixesOf(m.parent, seen);
    for (const p of parents.length ? parents : [""]) out.push(joinRoute(p, m.prefix));
    seen.delete(m);
  }
  return out;
}

for (const r of expressRoutes) {
  const prefixes = prefixesOf(r.keys);
  for (const prefix of prefixes.length ? prefixes : [""]) {
    addRoute({
      controller: r.receiver,
      handler: r.handler,
      method: r.method,
      path: joinRoute(basePath, prefix, r.sub),
      specPath: joinRoute(prefix, r.sub),
      file: r.file,
      line: r.line,
      node: r.node,
    });
  }
}

// ---------------------------------------------------------------------------
// Reachability: route -> upstream ops (with the hop chain), and back-references
// ---------------------------------------------------------------------------
const nodeRoutes = {}; // nodeId -> [routeIdx]
const opRoutes = {}; // opId -> [routeIdx]

for (const r of routes) {
  const parent = { [r.node]: null };
  const queue = [r.node];
  const seenOps = new Set();
  while (queue.length) {
    const cur = queue.shift();
    (nodeRoutes[cur] ||= []).push(r.idx);
    for (const opId of direct[cur] || []) {
      if (seenOps.has(opId)) continue;
      seenOps.add(opId);
      const via = [];
      for (let n = cur; n && n !== r.node; n = parent[n]) via.unshift(n);
      r.upstream.push({ op: opId, via });
      (opRoutes[opId] ||= []).push(r.idx);
    }
    for (const next of edges[cur] || []) {
      if (next in parent) continue;
      parent[next] = cur;
      queue.push(next);
    }
  }
}

// Upstream reach per node (memoised DFS, cycle safe) — lets service defs list what they hit.
const reachMemo = {};
function reach(id, stack = new Set()) {
  if (reachMemo[id]) return reachMemo[id];
  if (stack.has(id)) return new Set();
  stack.add(id);
  const out = new Set(direct[id] || []);
  for (const n of edges[id] || []) for (const o of reach(n, stack)) out.add(o);
  stack.delete(id);
  return (reachMemo[id] = out);
}
for (const id of Object.keys(nodes)) nodes[id].reaches = [...reach(id)];

// The BFF's own generated spec, so it can be annotated too.
const ownSpecFile = project.ownSpec ? abs(project.ownSpec) : null;
const hasOwnSpec = ownSpecFile && fs.existsSync(ownSpecFile);
if (hasOwnSpec) specs[rel(ownSpecFile)] = specLines(ownSpecFile);

process.stdout.write(
  JSON.stringify({
    root,
    basePath,
    generatedAt: new Date().toISOString(),
    ownSpec: hasOwnSpec ? rel(ownSpecFile) : null,
    ops,
    nodes,
    routes,
    callsites,
    nodeRoutes,
    opRoutes,
    specs,
  }),
);
