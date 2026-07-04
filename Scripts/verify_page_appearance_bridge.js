#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const projectRoot = path.resolve(__dirname, "..");
const sourcePath = path.join(projectRoot, "Sources", "ChatGPTWebView.swift");
const swiftSource = fs.readFileSync(sourcePath, "utf8");
const scriptMatch = swiftSource.match(
  /private static let pageAppearanceScript[\s\S]*?source: """\r?\n([\s\S]*?)\r?\n        """/
);

if (!scriptMatch) {
  throw new Error("pageAppearanceScript was not found");
}

const pageScript = decodeSwiftMultilineString(scriptMatch[1]);

function decodeSwiftMultilineString(value) {
  return value.replace(/\\\\/g, "\\");
}

class FakeStyle {
  constructor(initial = {}) {
    this.values = new Map();
    this.priorities = new Map();

    for (const [key, value] of Object.entries(initial)) {
      this.setProperty(key, value);
    }
  }

  setProperty(property, value, priority = "") {
    this.values.set(property, String(value));
    this.priorities.set(property, priority || "");
  }

  getPropertyValue(property) {
    return this.values.get(property) || "";
  }

  getPropertyPriority(property) {
    return this.priorities.get(property) || "";
  }

  get bottom() {
    return this.getPropertyValue("bottom");
  }

  set bottom(value) {
    this.setProperty("bottom", value);
  }

  get paddingBottom() {
    return this.getPropertyValue("padding-bottom") || this.getPropertyValue("paddingBottom");
  }

  set paddingBottom(value) {
    this.setProperty("padding-bottom", value);
  }
}

class FakeElement {
  constructor(tag, options = {}) {
    this.tagName = tag.toUpperCase();
    this.nodeType = 1;
    this.children = [];
    this.parentElement = null;
    this.ownerDocument = null;
    this.attrs = options.attrs || {};
    this.id = options.id || this.attrs.id || "";
    this.name = options.name || this.attrs.name || "";
    this.textContent = options.textContent || "";
    this.style = new FakeStyle(options.inlineStyle || {});
    this.computed = {
      display: "block",
      visibility: "visible",
      opacity: "1",
      position: "static",
      bottom: "auto",
      overflowY: "visible",
      ...(options.computed || {}),
    };
    this.rect = options.rect || rect(0, 0, 0, 0);
  }

  appendChild(child) {
    child.parentElement = this;
    child.ownerDocument = this.ownerDocument;
    this.children.push(child);
    return child;
  }

  setAttribute(name, value) {
    this.attrs[name] = String(value);
    if (name === "id") {
      this.id = String(value);
    }
    if (name === "name") {
      this.name = String(value);
    }
  }

  getAttribute(name) {
    if (name === "id") {
      return this.id;
    }
    if (name === "name") {
      return this.name;
    }
    return this.attrs[name] || "";
  }

  removeAttribute(name) {
    delete this.attrs[name];
    if (name === "id") {
      this.id = "";
    }
  }

  getBoundingClientRect() {
    return this.rect;
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  querySelectorAll(selector) {
    const out = [];
    const visit = (node) => {
      for (const child of node.children) {
        if (child.matches(selector)) {
          out.push(child);
        }
        visit(child);
      }
    };
    visit(this);
    return out;
  }

  closest(selector) {
    let node = this;
    while (node) {
      if (node.matches(selector)) {
        return node;
      }
      node = node.parentElement;
    }
    return null;
  }

  matches(selector) {
    return selector
      .split(",")
      .map((part) => part.trim())
      .filter(Boolean)
      .some((part) => this.matchesOne(part));
  }

  matchesOne(part) {
    const tag = this.tagName.toLowerCase();
    if (part === tag) {
      return true;
    }

    if (part === "body > *" || part === "main > *" || part === "[role='main'] > *") {
      return Boolean(this.parentElement);
    }

    const role = part.match(/^\[role='([^']+)'\]$/);
    if (role) {
      return this.attrs.role === role[1];
    }

    const dataTest = part.match(/^\[data-testid\*='([^']+)'\]$/);
    if (dataTest) {
      return String(this.attrs["data-testid"] || "").includes(dataTest[1]);
    }

    const klass = part.match(/^\[class\*='([^']+)'\]$/);
    if (klass) {
      return String(this.attrs.class || "").includes(klass[1]);
    }

    const style = part.match(/^\[style\*='([^']+)'\]$/);
    if (style) {
      return String(this.attrs.style || "").includes(style[1]);
    }

    return false;
  }
}

function rect(left, top, width, height) {
  return {
    left,
    top,
    width,
    height,
    right: left + width,
    bottom: top + height,
  };
}

function createDocument(elements) {
  const documentElement = new FakeElement("html", { rect: rect(0, 0, 430, 932) });
  const head = new FakeElement("head");
  const body = new FakeElement("body", { rect: rect(0, 0, 430, 932) });
  const allElements = [documentElement, head, body, ...elements];

  const document = {
    documentElement,
    head,
    body,
    scrollingElement: body,
    createElement(tag) {
      const element = new FakeElement(tag);
      element.ownerDocument = document;
      allElements.push(element);
      return element;
    },
    querySelector(selector) {
      if (selector === "meta[name='viewport']") {
        return allElements.find((element) => element.tagName === "META" && element.name === "viewport") || null;
      }

      return this.querySelectorAll(selector)[0] || null;
    },
    querySelectorAll(selector) {
      return allElements.filter((element) => element.matches(selector));
    },
  };

  for (const element of allElements) {
    element.ownerDocument = document;
  }

  documentElement.appendChild(head);
  documentElement.appendChild(body);
  for (const element of elements) {
    body.appendChild(element);
  }

  return { document, allElements };
}

function computedStyleFor(element) {
  return {
    ...element.computed,
    getPropertyValue(property) {
      return this[property] || element.style.getPropertyValue(property);
    },
  };
}

function runPageAppearanceScenario() {
  const header = new FakeElement("header", {
    rect: rect(0, 0, 430, 118),
    computed: { position: "fixed", bottom: "auto" },
    attrs: { class: "header navbar top-0" },
  });
  const composer = new FakeElement("form", {
    rect: rect(18, 760, 394, 112),
    computed: { position: "fixed", bottom: "0", overflowY: "visible" },
    attrs: { class: "composer prompt fixed", "data-testid": "composer" },
  });
  const main = new FakeElement("main", {
    rect: rect(0, 120, 430, 752),
    computed: { position: "static", overflowY: "auto", bottom: "auto" },
    attrs: { role: "main", class: "conversation scroll overflow-y-auto" },
  });
  const drawer = new FakeElement("aside", {
    rect: rect(0, 0, 300, 932),
    computed: { position: "fixed", bottom: "auto" },
    textContent: "新聊天 搜索聊天 文件库 项目",
    attrs: { class: "sidebar drawer" },
  });

  const { document } = createDocument([header, composer, main, drawer]);
  const timeouts = [];
  const observed = [];

  class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback;
    }

    observe(target, options) {
      observed.push({ target, options });
    }
  }

  const window = {
    __gptNativePageAppearanceInstalled: false,
    innerWidth: 430,
    innerHeight: 932,
    visualViewport: {
      addEventListener() {},
    },
    addEventListener() {},
    getComputedStyle: computedStyleFor,
    setTimeout(callback, delay) {
      timeouts.push(delay);
      callback();
      return timeouts.length;
    },
    requestAnimationFrame(callback) {
      callback();
    },
  };

  const context = {
    window,
    document,
    Node: { ELEMENT_NODE: 1 },
    MutationObserver: FakeMutationObserver,
    WeakMap,
    Set,
    Array,
    Math,
    Number,
    String,
    performance: { now: () => 1000 },
    console,
  };
  context.globalThis = context;

  vm.createContext(context);
  vm.runInContext(pageScript, context, { timeout: 1000 });

  const styleElement = document.head.children.find((element) => element.id === "gpt-native-page-appearance");
  const drawerMask = document.documentElement.children.find((element) => element.id === "gpt-native-drawer-mask");
  const viewport = document.querySelector("meta[name='viewport']");

  return { header, composer, main, drawer, drawerMask, styleElement, viewport, observed, document };
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const result = runPageAppearanceScenario();
const css = result.styleElement?.textContent || "";

assert(result.viewport?.getAttribute("content").includes("viewport-fit=cover"), "viewport-fit=cover was not applied");
assert(css.includes("--gpt-native-safe-surface: #ffffff"), "light safe surface CSS is missing");
assert(css.includes("scrollbar-width: none"), "scrollbar hiding CSS is missing");
assert(css.includes("*::-webkit-scrollbar"), "webkit scrollbar hiding CSS is missing");
assert(css.includes("#gpt-native-drawer-mask"), "drawer mask CSS is missing");
assert(css.includes("scroll-margin-bottom"), "media scroll margin CSS is missing");
assert(css.includes("-webkit-touch-callout: none"), "image touch-callout CSS is missing");

assert(result.header.style.getPropertyValue("background") === "var(--gpt-native-safe-surface)", "top header surface was not painted");
assert(result.header.style.getPropertyPriority("background") === "important", "top header surface is not important");
assert(result.header.style.getPropertyValue("background-image") === "none", "top header background image was not removed");
assert(result.header.style.getPropertyValue("box-shadow") === "none", "top header shadow was not removed");

assert(
  /^calc\(0(px)? \+ var\(--gpt-native-safe-bottom\)\)$/.test(result.composer.style.getPropertyValue("bottom")),
  "bottom composer was not offset by safe area"
);
assert(result.composer.style.getPropertyValue("background") === "var(--gpt-native-safe-surface)", "bottom composer surface was not painted");
assert(
  result.document.documentElement.style.getPropertyValue("--gpt-native-composer-clearance") !== "0px",
  "composer clearance was not raised"
);
assert(
  result.main.style.getPropertyValue("padding-bottom").includes("var(--gpt-native-composer-clearance)"),
  "scroll content was not padded for composer clearance"
);

assert(result.drawerMask?.getAttribute("data-visible") === "true", "drawer mask was not made visible for open drawer");
assert(
  result.document.documentElement.style.getPropertyValue("--gpt-native-drawer-mask-left") === "300px",
  "drawer mask left edge was not set from drawer width"
);
assert(result.observed.length === 1, "layout mutation observer was not installed");

console.log("pageAppearance bridge behavior tests ok");
