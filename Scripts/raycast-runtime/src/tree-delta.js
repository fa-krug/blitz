// A commit crosses to Swift as a delta against the last tree Swift accepted: an element whose own
// content and every descendant are unchanged crosses as `{"$same": id}`, and Swift reuses the
// node it decoded for that id. Only an envelope carrying `delta: true` has its references read,
// so a tree that cannot be referenced safely crosses whole without the flag.
//
// Elements are compared and referenced at three positions only, the ones
// `RenderTree.referenceableNodes` walks: an element's `children` (the root's are its screens), a
// prop holding an element (a single slot such as `actions`), and an array prop's element items.

export function isElement(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Number.isInteger(value.id) &&
    value.id > 0 &&
    typeof value.type === "string" &&
    value.type !== "#text" &&
    value.props !== null &&
    typeof value.props === "object" &&
    !Array.isArray(value.props) &&
    Array.isArray(value.children) &&
    // Swift reads these two as a handler and a date before it ever tries a node.
    typeof value.$fn !== "string" &&
    typeof value.$date !== "string"
  );
}

const isReferenceLike = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value) && "$same" in value;

/// Plain JSON equality: allocation-free, which is what keeps a 1,000-row comparison cheap.
function equal(a, b) {
  if (a === b) return true;
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let index = 0; index < a.length; index++) if (!equal(a[index], b[index])) return false;
    return true;
  }
  if (Array.isArray(b)) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  for (const key of keys) if (!Object.hasOwn(b, key) || !equal(a[key], b[key])) return false;
  return true;
}

export class TreeDelta {
  constructor() {
    this.reset();
  }

  /// Forgets the base, so the next commit crosses whole.
  reset() {
    this.nodes = new Map();
    this.screens = null;
    this.whole = null;
  }

  /// `null` when the tree matches the base; otherwise the JSON to send and `accept`, which makes
  /// this tree the base once Swift has decoded it.
  encode(tree) {
    const previous = this.nodes;
    const nodes = new Map();
    // Identity, not id: only the exact objects found at an element position may be replaced.
    const unchanged = new Set();
    // A repeated id, or a raw value shaped like a reference, would make a reference ambiguous.
    let safe = true;

    // At an element position: whether `value` is an element whose subtree matches `before`'s slot.
    const position = (value, before) => {
      if (value === null || typeof value !== "object") return value === before;
      if (!isElement(value)) {
        if (isReferenceLike(value)) safe = false;
        return equal(value, before);
      }
      return visit(value) && isElement(before) && before.id === value.id;
    };

    const visit = (node) => {
      const count = nodes.size;
      if (nodes.set(node.id, node).size === count) safe = false;
      const old = previous.get(node.id);
      let same = old !== undefined && old.type === node.type;
      const keys = Object.keys(node.props);
      if (same && keys.length !== Object.keys(old.props).length) same = false;
      for (const key of keys) {
        const value = node.props[key];
        const before = same && Object.hasOwn(old.props, key) ? old.props[key] : undefined;
        if (!Array.isArray(value)) {
          if (!position(value, before)) same = false;
          continue;
        }
        if (!Array.isArray(before) || before.length !== value.length) same = false;
        for (let index = 0; index < value.length; index++) {
          if (!position(value[index], same ? before[index] : undefined)) same = false;
        }
      }
      if (same && node.children.length !== old.children.length) same = false;
      for (let index = 0; index < node.children.length; index++) {
        if (!position(node.children[index], same ? old.children[index] : undefined)) same = false;
      }
      if (same) unchanged.add(node);
      return same;
    };

    for (const screen of tree.children) if (isElement(screen)) visit(screen);
    const screens = tree.children.map((child) => child.id);
    if (!safe) {
      const json = JSON.stringify(tree);
      if (json === this.whole) return null;
      return {
        json,
        accept: () => {
          this.reset();
          this.whole = json;
        },
      };
    }
    const sameScreens =
      this.screens !== null &&
      screens.length === this.screens.length &&
      tree.children.every(
        (screen, index) => unchanged.has(screen) && screens[index] === this.screens[index],
      );
    if (sameScreens) return null;
    // With nothing to reference the flag is left off, so Swift takes its plain, faster decode.
    const json =
      unchanged.size === 0
        ? JSON.stringify(tree)
        : JSON.stringify({ delta: true, children: tree.children }, (_, value) =>
            unchanged.has(value) ? { $same: value.id } : value,
          );
    return {
      json,
      accept: () => {
        this.nodes = nodes;
        this.screens = screens;
      },
    };
  }
}

/// The receiving half, for the Node harness: `nodes` is the previous tree's id → element table.
export function resolveTree(json, nodes) {
  const envelope = JSON.parse(json);
  if (!envelope.delta) return { tree: envelope, nodes: collect(envelope) };
  const resolve = (value) => {
    if (value !== null && typeof value === "object" && !Array.isArray(value) && "$same" in value) {
      const node = nodes.get(value.$same);
      if (!node) throw new Error(`unknown reference ${value.$same}`);
      return node;
    }
    if (!isElement(value)) return value;
    const props = {};
    for (const key of Object.keys(value.props)) {
      const prop = value.props[key];
      props[key] = Array.isArray(prop) ? prop.map(resolve) : resolve(prop);
    }
    return { ...value, props, children: value.children.map(resolve) };
  };
  const tree = { children: envelope.children.map(resolve) };
  return { tree, nodes: collect(tree) };
}

function collect(tree) {
  const nodes = new Map();
  const walk = (node) => {
    if (!isElement(node)) return;
    nodes.set(node.id, node);
    for (const value of Object.values(node.props)) {
      if (Array.isArray(value)) value.forEach(walk);
      else walk(value);
    }
    node.children.forEach(walk);
  };
  tree.children.forEach(walk);
  return nodes;
}
