// The `require` an extension bundle sees: the registry below for React, `@raycast/api` and the Node
// builtins, then any pre-built CommonJS packages a store bundle ships under its own `node_modules/`.

import { nodeModules } from "./node-shims.js";

const registry = new Map();

export function defineModule(name, exports) {
  registry.set(name, exports);
}

for (const name of Object.keys(nodeModules)) defineModule(name, nodeModules[name]);

const fs = nodeModules.fs;
const path = nodeModules.path;
const unregistered = Symbol("unregistered");
const fileModules = new Map();

function notFound(key) {
  throw new Error(
    `Cannot find module '${key}'. Blitz provides React, @raycast/api, a subset of Node builtins and the packages an extension ships in node_modules — see docs/features/extensions.md.`,
  );
}

const packageName = (key) => (key.startsWith("@") ? key.split("/").slice(0, 2).join("/") : key.split("/")[0]);

function registered(key) {
  if (registry.has(key)) return registry.get(key);
  // Deep imports into a provided package (`react-dom/client`) resolve to the package itself rather
  // than exploding, which is enough for the handful of bundles that reference them defensively.
  const root = packageName(key);
  return registry.has(root) ? registry.get(root) : unregistered;
}

export function requireModule(name) {
  const key = String(name);
  const module = registered(key);
  return module === unregistered ? notFound(key) : module;
}

const isPathRequest = (request) =>
  request === "." || request === ".." || /^\.{1,2}\//.test(request) || request.startsWith("/");

function asFile(base) {
  for (const candidate of [base, `${base}.js`, `${base}.json`, `${base}.cjs`]) {
    if (fs.statSync(candidate, { throwIfNoEntry: false })?.isFile()) return candidate;
  }
  return null;
}

function readManifest(directory) {
  try {
    return JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
  } catch {
    return null;
  }
}

/// Only the conditions a CommonJS `require` under Node matches; `import` targets are ESM.
function conditionalTarget(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(conditionalTarget).find(Boolean) ?? null;
  if (!value || typeof value !== "object") return null;
  for (const [condition, target] of Object.entries(value)) {
    if (!["require", "node", "default"].includes(condition)) continue;
    const resolved = conditionalTarget(target);
    if (resolved) return resolved;
  }
  return null;
}

function exportsTarget(exportsField, subpath) {
  const key = subpath ? `./${subpath}` : ".";
  if (typeof exportsField === "string" || Array.isArray(exportsField)) {
    return key === "." ? conditionalTarget(exportsField) : null;
  }
  if (!exportsField || typeof exportsField !== "object") return null;
  if (!Object.keys(exportsField).some((entry) => entry.startsWith("."))) {
    return key === "." ? conditionalTarget(exportsField) : null;
  }
  if (Object.hasOwn(exportsField, key)) return conditionalTarget(exportsField[key]);
  // Node's order: the longest prefix before the `*` wins, then the longest pattern.
  const patterns = Object.keys(exportsField).filter((pattern) => pattern.includes("*"));
  patterns.sort((a, b) => b.indexOf("*") - a.indexOf("*") || b.length - a.length);
  for (const pattern of patterns) {
    const [prefix, suffix] = [pattern.slice(0, pattern.indexOf("*")), pattern.slice(pattern.indexOf("*") + 1)];
    if (!key.startsWith(prefix) || !key.endsWith(suffix) || key.length < prefix.length + suffix.length) continue;
    const target = conditionalTarget(exportsField[pattern]);
    return target ? target.replaceAll("*", key.slice(prefix.length, key.length - suffix.length)) : null;
  }
  return null;
}

function asDirectory(directory) {
  if (!fs.statSync(directory, { throwIfNoEntry: false })?.isDirectory()) return null;
  const manifest = readManifest(directory);
  if (manifest && Object.hasOwn(manifest, "exports")) {
    const target = exportsTarget(manifest.exports, "");
    return target ? asFile(path.join(directory, target)) : null;
  }
  if (typeof manifest?.main === "string") {
    const main = path.join(directory, manifest.main);
    const resolved = asFile(main) ?? asFile(path.join(main, "index"));
    if (resolved) return resolved;
  }
  return asFile(path.join(directory, "index"));
}

/// Walks up from the caller but never above the extension root: packages there are the user's.
function resolvePackage(request, fromDir, root) {
  const name = packageName(request);
  const subpath = request.slice(name.length + 1);
  for (let dir = fromDir; dir === root || dir.startsWith(`${root}/`); dir = dir === root ? "" : path.dirname(dir)) {
    const directory = path.join(dir, "node_modules", name);
    if (!fs.existsSync(directory)) continue;
    const manifest = readManifest(directory);
    if (manifest && Object.hasOwn(manifest, "exports")) {
      const target = exportsTarget(manifest.exports, subpath);
      return target ? asFile(path.join(directory, target)) : null;
    }
    if (!subpath) return asDirectory(directory);
    const target = path.join(directory, subpath);
    return asFile(target) ?? asDirectory(target);
  }
  return null;
}

function resolveFile(request, fromDir, root) {
  if (isPathRequest(request)) {
    const target = path.resolve(fromDir, request);
    return asFile(target) ?? asDirectory(target);
  }
  return request.startsWith("node:") ? null : resolvePackage(request, fromDir, root);
}

function loadFile(file, root) {
  const cached = fileModules.get(file);
  if (cached) return cached.exports;
  const module = { exports: {}, id: file, filename: file, loaded: false, children: [], paths: [] };
  // Published before it runs, so a dependency cycle sees the partial exports as Node's does.
  fileModules.set(file, module);
  const dirname = path.dirname(file);
  try {
    if (file.endsWith(".json")) {
      module.exports = JSON.parse(fs.readFileSync(file, "utf8"));
    } else {
      const factory = globalThis.__blitzCompile(fs.readFileSync(file, "utf8"), file);
      factory(module.exports, localRequire(dirname, root), module, file, dirname);
    }
    module.loaded = true;
    return module.exports;
  } catch (error) {
    fileModules.delete(file);
    throw error;
  }
}

function localRequire(fromDir, root) {
  const resolve = (request) => {
    const key = String(request);
    if (!isPathRequest(key) && registered(key) !== unregistered) return key;
    return resolveFile(key, fromDir, root) ?? notFound(key);
  };
  const require = (request) => {
    const key = String(request);
    if (!isPathRequest(key)) {
      const module = registered(key);
      if (module !== unregistered) return module;
    }
    return loadFile(resolve(key), root);
  };
  require.resolve = resolve;
  require.cache = {};
  return require;
}

// apple-passwords lazily requires `@raycast/api` through it; the base path never matters here.
const nodeRequire = (name) => requireModule(name);
nodeRequire.resolve = (name) => String(name);
nodeRequire.cache = {};
nodeModules.module.createRequire = () => nodeRequire;

/// Evaluate one CJS bundle. `filename`/`dirname` matter: extensions resolve bundled assets relative
/// to `__dirname`, and `environment.assetsPath` points at the same directory.
export function evaluateCommonJS(code, filename, dirname) {
  const module = { exports: {}, id: filename, filename, loaded: false, children: [], paths: [] };
  const factory = globalThis.__blitzCompile(code, filename);
  // The command's own directory is the extension root.
  factory(module.exports, localRequire(dirname, dirname), module, filename, dirname);
  module.loaded = true;
  return module.exports;
}
