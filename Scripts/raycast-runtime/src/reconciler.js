// A React host renderer whose "DOM" is a plain JSON tree that Swift renders natively.
//
// Two conventions make the Raycast component surface expressible:
//   * `__slot` instances fold their children into the parent's props under a name, so element-valued
//     props (`actions={<ActionPanel/>}`, `detail={<List.Item.Detail/>}`) reach Swift as structure.
//   * function props become `{"$fn": "<nodeId>:<propName>"}` handles; Swift dispatches them back by id.

import Reconciler from "react-reconciler";
import { DefaultEventPriority } from "react-reconciler/constants";
import { reportUncaught } from "./polyfills.js";

export const SLOT_TYPE = "__slot";

const ITEM_TYPES = new Set(["List.Item", "Grid.Item"]);
const ACTION_GROUPS = new Set(["ActionPanel.Section", "ActionPanel.Submenu"]);
const MODIFIERS = new Set(["cmd", "ctrl", "opt", "alt", "shift"]);

/// Swift's `ExtensionKeyShortcut.isCommandReturn`: exactly ⌘, on return or enter.
function claimsCommandReturn(shortcut) {
  const resolved = shortcut?.macOS ?? shortcut;
  if (resolved?.key !== "return" && resolved?.key !== "enter") return false;
  const modifiers = new Set(
    (resolved.modifiers ?? []).filter((name) => MODIFIERS.has(name)).map((name) => (name === "alt" ? "opt" : name)),
  );
  return modifiers.size === 1 && modifiers.has("cmd");
}

let nextInstanceId = 1;

function createNode(type, props) {
  return { id: nextInstanceId++, type, props: props ?? {}, children: [] };
}

const hostConfig = {
  supportsMutation: true,
  supportsPersistence: false,
  supportsHydration: false,
  isPrimaryRenderer: true,
  noTimeout: -1,
  warnsIfNotActing: false,

  getRootHostContext: () => null,
  getChildHostContext: (parentContext) => parentContext,
  getPublicInstance: (instance) => instance,

  createInstance: (type, props) => createNode(type, props),
  createTextInstance: (text) => ({ id: nextInstanceId++, type: "#text", text, children: [] }),

  appendInitialChild: (parent, child) => parent.children.push(child),
  appendChild: (parent, child) => {
    detach(parent, child);
    parent.children.push(child);
  },
  appendChildToContainer: (container, child) => {
    detach(container, child);
    container.children.push(child);
  },
  insertBefore: (parent, child, before) => insert(parent, child, before),
  insertInContainerBefore: (container, child, before) => insert(container, child, before),
  removeChild: (parent, child) => detach(parent, child),
  removeChildFromContainer: (container, child) => detach(container, child),
  clearContainer: (container) => {
    container.children.length = 0;
  },

  finalizeInitialChildren: () => false,
  shouldSetTextContent: () => false,
  commitUpdate: (instance, type, prevProps, nextProps) => {
    instance.props = nextProps;
  },
  commitTextUpdate: (instance, prev, next) => {
    instance.text = next;
  },
  commitMount: () => {},
  resetTextContent: () => {},

  prepareForCommit: () => null,
  resetAfterCommit: (container) => container.onCommit(),
  preparePortalMount: () => {},
  detachDeletedInstance: () => {},

  scheduleTimeout: (fn, delay) => setTimeout(fn, delay),
  cancelTimeout: (handle) => clearTimeout(handle),

  // React 19 update-priority hooks: a single-surface renderer has no event lanes to distinguish.
  getCurrentUpdatePriority: () => DefaultEventPriority,
  setCurrentUpdatePriority: () => {},
  resolveUpdatePriority: () => DefaultEventPriority,
  getCurrentEventPriority: () => DefaultEventPriority,
  shouldAttemptEagerTransition: () => false,
  requestPostPaintCallback: () => {},
  trackSchedulerEvent: () => {},
  resolveEventType: () => null,
  resolveEventTimeStamp: () => -1.1,
  maySuspendCommit: () => false,
  preloadInstance: () => true,
  startSuspendingCommit: () => {},
  suspendInstance: () => {},
  waitForCommitToBeReady: () => null,
  NotPendingTransition: null,
  HostTransitionContext: {
    $$typeof: Symbol.for("react.context"),
    Provider: null,
    Consumer: null,
    _currentValue: null,
    _currentValue2: null,
    _threadCount: 0,
  },
  resetFormInstance: () => {},
  bindToConsole: (method, args) => () => method.apply(console, args),

  beforeActiveInstanceBlur: () => {},
  afterActiveInstanceBlur: () => {},
  prepareScopeUpdate: () => {},
  getInstanceFromScope: () => null,
  getInstanceFromNode: () => null,
};

/// A `single` slot (`detail`, `actions`, …) expects one element, but a Fragment passed as the prop
/// (`detail={<><List.Item.Detail markdown={…} /><List.Item.Detail metadata={…} /></>}`) flattens into
/// several same-typed siblings by the time the reconciler commits — keeping only the first silently
/// drops the rest. Merge same-typed siblings into one node instead; a heterogeneous fragment falls
/// back to the first element, matching the prior behaviour.
function mergeSingleSlot(contents) {
  if (contents.length === 1) return contents[0];
  const [first, ...rest] = contents;
  if (rest.some((node) => node.type !== first.type)) return first;
  const merged = { id: first.id, type: first.type, props: { ...first.props }, children: [...first.children] };
  for (const node of rest) {
    Object.assign(merged.props, node.props);
    merged.children.push(...node.children);
  }
  return merged;
}

function detach(parent, child) {
  const index = parent.children.indexOf(child);
  if (index >= 0) parent.children.splice(index, 1);
}

function insert(parent, child, before) {
  detach(parent, child);
  const index = parent.children.indexOf(before);
  if (index < 0) parent.children.push(child);
  else parent.children.splice(index, 0, child);
}

const reconciler = Reconciler(hostConfig);

/// One mounted command. `onTree` fires after every commit with the serialized tree; handler lookups
/// go through `handlers`, which is rebuilt on each serialization so a dispatch always hits the
/// callback from the newest render.
export class Surface {
  constructor(onTree, onError, onActionError = onError, onPanel = () => {}) {
    this.handlers = new Map();
    this.onTree = onTree;
    this.onPanel = onPanel;
    this.onError = onError;
    this.onActionError = onActionError;
    this.container = { id: 0, type: "#root", props: {}, children: [], onCommit: () => this.flush() };
    // Items carry previews; the selected one's whole panel crosses alone, so its list stays put.
    this.focusedItem = null;
    this.sentPanel = null;
    this.root = reconciler.createContainer(
      this.container,
      0, // LegacyRoot — extensions never opt into concurrent-only behaviour
      null,
      false,
      null,
      "blitz",
      (error) => this.onError(error),
      (error) => this.onError(error),
      (error) => this.onError(error),
      null,
    );
  }

  render(element) {
    reconciler.updateContainer(element, this.root, null, null);
  }

  unmount() {
    try {
      reconciler.updateContainer(null, this.root, null, null);
    } catch (error) {
      reportUncaught(error);
    }
    this.handlers.clear();
  }

  flush() {
    this.handlers.clear();
    const children = this.container.children.map((child) => this.serializeScreen(child)).filter(Boolean);
    this.onTree({ children });
    this.sendPanel();
  }

  /// Swift's selection moved to another List or Grid item.
  focusItem(id) {
    if (id === this.focusedItem) return;
    this.focusedItem = id;
    this.sentPanel = null;
    this.sendPanel();
  }

  /// Serializing registers the panel's handlers on every flush; it crosses only when it changed.
  sendPanel() {
    const item = this.mountedItem(this.focusedItem);
    const slot = item?.children.find((child) => child.type === SLOT_TYPE && child.props?.name === "actions");
    if (!slot) return;
    const contents = slot.children.map((entry) => this.serialize(entry)).filter(Boolean);
    if (!contents.length) return;
    const json = JSON.stringify(slot.props.single ? mergeSingleSlot(contents) : contents[0]);
    if (json === this.sentPanel) return;
    this.sentPanel = json;
    this.onPanel(item.id, json);
  }

  mountedItem(id) {
    if (id === null) return null;
    let found = null;
    const visit = (node) => {
      if (found) return;
      if (ITEM_TYPES.has(node.type)) {
        if (node.id === id) found = node;
        return;
      }
      for (const child of node.children) visit(child);
    };
    for (const screen of this.container.children) {
      if (screen.type !== "__screen" || screen.props.active !== false) visit(screen);
    }
    return found;
  }

  /// What ↵, ⌘↵ and the footer read off an item: its first two actions and any claiming ⌘↵.
  previewPanel(panel) {
    const kept = new Set();
    let position = 0;
    const visit = (node, path) => {
      for (const child of node.children) {
        if (child.type === "Action") {
          if (position++ < 2 || claimsCommandReturn(child.props.shortcut)) {
            kept.add(child);
            for (const group of path) kept.add(group);
          }
        } else if (ACTION_GROUPS.has(child.type)) {
          visit(child, [...path, child]);
        }
      }
    };
    visit(panel, []);
    return this.serialize(panel, kept);
  }

  /// Swift renders only the active screen; a covered one keeps its React state but crosses as a stub.
  serializeScreen(node) {
    if (node.type === "__screen" && node.props.active === false) {
      return { id: node.id, type: node.type, props: { active: false }, children: [] };
    }
    return this.serialize(node);
  }

  /// A throwing handler is the action's failure, not the screen's: the tree it rendered stays up.
  dispatch(handlerId, args, onComplete) {
    const handler = this.handlers.get(handlerId);
    if (!handler) return false;
    let result;
    try {
      result = handler(...args);
    } catch (error) {
      this.onActionError(error);
      return true;
    }
    Promise.resolve(result).then(() => onComplete?.(), (error) => this.onActionError(error));
    return true;
  }

  /// `kept` prunes a preview panel to the actions it holds and the groups around them.
  serialize(node, kept) {
    if (node.type === "#text") return { type: "#text", text: String(node.text) };

    const props = {};
    for (const key of Object.keys(node.props)) {
      if (key === "children") continue;
      const value = this.encode(node.props[key], node.id, key);
      if (value !== undefined) props[key] = value;
    }

    const children = [];
    for (const child of node.children) {
      // A slot child is structure for the parent, not a row of its own.
      if (child.type === SLOT_TYPE) {
        const name = child.props?.name;
        if (!name) continue;
        const preview = name === "actions" && ITEM_TYPES.has(node.type);
        const contents = child.children
          .map((entry) => (preview ? this.previewPanel(entry) : this.serialize(entry)))
          .filter(Boolean);
        if (contents.length) props[name] = child.props.single ? mergeSingleSlot(contents) : contents;
        continue;
      }
      if (kept && !kept.has(child)) continue;
      const serialized = this.serialize(child, child.type === "Action" ? undefined : kept);
      if (serialized) children.push(serialized);
    }

    return { id: node.id, type: node.type, props, children };
  }

  /// JSON-safe encoding of a prop value. Functions become dispatchable handles; Dates keep their
  /// type so Swift can round-trip a Form.DatePicker value.
  encode(value, nodeId, key) {
    if (value === undefined || value === null) return value === null ? null : undefined;
    switch (typeof value) {
      case "function": {
        const handlerId = `${nodeId}:${key}`;
        this.handlers.set(handlerId, value);
        return { $fn: handlerId };
      }
      case "string":
      case "number":
      case "boolean":
        return value;
      case "bigint":
        return Number(value);
      case "symbol":
        return undefined;
      default:
        break;
    }
    if (value instanceof Date) return { $date: value.toISOString() };
    if (Array.isArray(value)) {
      return value.map((item, index) => this.encode(item, nodeId, `${key}.${index}`) ?? null);
    }
    // A React element that reached us as a plain prop (rather than through a slot) can't be
    // rendered; drop it instead of serializing React internals.
    if (value.$$typeof) return undefined;
    const out = {};
    for (const name of Object.keys(value)) {
      const encoded = this.encode(value[name], nodeId, `${key}.${name}`);
      if (encoded !== undefined) out[name] = encoded;
    }
    return out;
  }
}

export function flushSync(fn) {
  return reconciler.flushSyncWork ? reconciler.flushSyncWork(fn) : fn?.();
}

export function actBatch(fn) {
  return fn();
}
