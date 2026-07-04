#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const projectRoot = path.resolve(__dirname, "..");
const sourcePath = path.join(projectRoot, "Sources", "ChatGPTWebView.swift");
const swiftSource = fs.readFileSync(sourcePath, "utf8");
const scriptMatch = swiftSource.match(
  /private static let imageSaveBridgeScript[\s\S]*?source: """\r?\n([\s\S]*?)\r?\n        """/
);

if (!scriptMatch) {
  throw new Error("imageSaveBridgeScript was not found");
}

const bridgeScript = decodeSwiftMultilineString(scriptMatch[1]);

function decodeSwiftMultilineString(value) {
  return value.replace(/\\\\/g, "\\");
}

class FakeElement {
  constructor(tag, options = {}) {
    this.tagName = tag.toUpperCase();
    this.nodeType = 1;
    this.isConnected = options.isConnected ?? true;
    this.attrs = options.attrs || {};
    this.children = options.children || [];
    this.parentElement = options.parentElement || null;
    this.rect = options.rect || rect(0, 0, 0, 0);
    this.currentSrc = options.currentSrc || "";
    this.src = options.src || "";
    this.naturalWidth = options.naturalWidth || 0;
    this.naturalHeight = options.naturalHeight || 0;
    this.width = options.width || 0;
    this.height = options.height || 0;
    this.backgroundImage = options.backgroundImage || "none";
    this.href = options.href || "";

    for (const child of this.children) {
      child.parentElement = this;
    }
  }

  getContext() {
    return this.tagName === "CANVAS" ? {} : null;
  }

  getAttribute(name) {
    return this.attrs[name] || "";
  }

  hasAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attrs, name);
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
      for (const child of node.children || []) {
        if (
          (selector.includes("img") && child.tagName === "IMG") ||
          (selector.includes("canvas") && child.tagName === "CANVAS") ||
          (selector.includes("background-image") && child.backgroundImage !== "none")
        ) {
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
      .some((part) => this.matchesOne(part));
  }

  matchesOne(part) {
    if (!part) {
      return false;
    }

    const tag = this.tagName.toLowerCase();
    if (part === tag) {
      return true;
    }

    if (part === "a[href]") {
      return tag === "a" && Boolean(this.href || this.attrs.href);
    }

    const role = part.match(/^\[role='([^']+)'\]$/);
    if (role) {
      return this.attrs.role === role[1];
    }

    const editable = part.match(/^\[contenteditable='([^']+)'\]$/);
    if (editable) {
      return this.attrs.contenteditable === editable[1];
    }

    const dataTest = part.match(/^\[data-testid\*='([^']+)'\]$/);
    if (dataTest) {
      return String(this.attrs["data-testid"] || "").includes(dataTest[1]);
    }

    const klass = part.match(/^\[class\*='([^']+)'\]$/);
    if (klass) {
      return String(this.attrs.class || "").includes(klass[1]);
    }

    return false;
  }

  toDataURL() {
    return "data:image/png;base64,QUJDRA==";
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

function runScenario({ images = [], canvases = [], backgrounds = [], links = [], elementsAtPoint = [] }, action) {
  const posts = [];
  const document = {
    images,
    querySelectorAll(selector) {
      if (selector === "canvas") {
        return canvases;
      }

      if (selector === "a[href]") {
        return links;
      }

      if (
        selector.includes("background-image") ||
        selector.includes("[role=") ||
        selector.includes("figure") ||
        selector.includes("button")
      ) {
        return backgrounds.concat(links);
      }

      return images.concat(canvases, backgrounds, links);
    },
    elementsFromPoint() {
      return elementsAtPoint;
    },
    elementFromPoint() {
      return elementsAtPoint[0] || null;
    },
  };

  const window = {
    __gptNativeImageSaveBridgeInstalled: false,
    innerWidth: 430,
    innerHeight: 932,
    location: { href: "https://chatgpt.com/" },
    webkit: {
      messageHandlers: {
        gptNativeImageSave: {
          postMessage(payload) {
            posts.push(payload);
          },
        },
      },
    },
    getComputedStyle(node) {
      return { backgroundImage: node.backgroundImage || "none" };
    },
  };

  const context = {
    window,
    document,
    Node: { ELEMENT_NODE: 1 },
    URL,
    String,
    Number,
    Math,
    Array,
    Date,
    RegExp,
    Promise,
    setTimeout,
    console,
    fetch: async () => {
      throw new Error("fetch should not be called by these tests");
    },
  };
  context.globalThis = context;

  vm.createContext(context);
  vm.runInContext(bridgeScript, context, { timeout: 1000 });
  return action(window, posts);
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function main() {
  const image = new FakeElement("img", {
    currentSrc: "https://example.com/image.png",
    naturalWidth: 1024,
    naturalHeight: 1024,
    rect: rect(40, 180, 350, 350),
    attrs: { alt: "generated" },
  });

  const smallImage = new FakeElement("img", {
    currentSrc: "https://example.com/small.png",
    naturalWidth: 64,
    naturalHeight: 64,
    rect: rect(20, 20, 32, 32),
  });

  const composer = new FakeElement("textarea", {
    rect: rect(24, 790, 380, 58),
    attrs: { class: "composer prompt", "data-testid": "composer" },
  });

  const header = new FakeElement("header", {
    rect: rect(0, 0, 430, 120),
    attrs: { class: "header navbar" },
  });

  const canvas = new FakeElement("canvas", {
    width: 1024,
    height: 1024,
    rect: rect(40, 180, 350, 350),
  });

  const background = new FakeElement("div", {
    backgroundImage: 'url("https://example.com/background.webp")',
    rect: rect(40, 180, 350, 350),
    attrs: { class: "image" },
  });

  const link = new FakeElement("a", {
    href: "https://example.com/generated.jpeg",
    rect: rect(40, 180, 350, 350),
    attrs: { href: "https://example.com/generated.jpeg" },
  });

  const directImage = runScenario({ images: [image], elementsAtPoint: [image] }, (window) =>
    window.__gptNativeImageAtPoint(120, 220)
  );
  assert(directImage?.url === "https://example.com/image.png", "direct image hit failed");

  const composerHit = runScenario({ images: [image], elementsAtPoint: [composer] }, (window) =>
    window.__gptNativeImageAtPoint(100, 820)
  );
  assert(composerHit === null, "composer long press should not open image menu");

  const headerHit = runScenario({ images: [image], elementsAtPoint: [header] }, (window) =>
    window.__gptNativeImageAtPoint(100, 52)
  );
  assert(headerHit === null, "header long press should not open image menu");

  const largeFallback = runScenario({ images: [image], elementsAtPoint: [] }, (window) =>
    window.__gptNativeImageAtPoint(15, 15)
  );
  assert(largeFallback?.url === "https://example.com/image.png", "large visible fallback failed");

  const smallFallback = runScenario({ images: [smallImage], elementsAtPoint: [] }, (window) =>
    window.__gptNativeImageAtPoint(390, 800)
  );
  assert(smallFallback === null, "small image should not trigger large-image fallback");

  const canvasHit = runScenario({ canvases: [canvas], elementsAtPoint: [canvas] }, (window) =>
    window.__gptNativeImageAtPoint(120, 220)
  );
  assert(String(canvasHit?.url || "").startsWith("data:image/png;base64,"), "canvas hit failed");

  const backgroundHit = runScenario({ backgrounds: [background], elementsAtPoint: [background] }, (window) =>
    window.__gptNativeImageAtPoint(120, 220)
  );
  assert(backgroundHit?.url === "https://example.com/background.webp", "background image hit failed");

  const linkHit = runScenario({ links: [link], elementsAtPoint: [link] }, (window) =>
    window.__gptNativeImageAtPoint(120, 220)
  );
  assert(linkHit?.url === "https://example.com/generated.jpeg", "image link hit failed");

  const posts = await runScenario({}, async (window, posted) => {
    await window.__gptNativeSaveURL("data:image/png;base64,QUJDRA==", "chatgpt-canvas-1.png");
    return posted;
  });
  const chunk = posts.find((payload) => payload.type === "imageChunk");
  assert(chunk, "data URL save did not post an image chunk");
  assert(chunk.filename === "chatgpt-canvas-1.png", `filename extension guard failed: ${chunk.filename}`);

  console.log("imageSaveBridge behavior tests ok");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
