"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.buildPlist = buildPlist;
const DOCTYPE = '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">';
function escapeXml(value) {
    return value
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
}
function renderValue(value, indent) {
    if (typeof value === "string") {
        return `${indent}<string>${escapeXml(value)}</string>`;
    }
    if (typeof value === "boolean") {
        return `${indent}<${value ? "true" : "false"}/>`;
    }
    if (typeof value === "number") {
        const tag = Number.isInteger(value) ? "integer" : "real";
        return `${indent}<${tag}>${value}</${tag}>`;
    }
    if (Array.isArray(value)) {
        if (value.length === 0) {
            return `${indent}<array/>`;
        }
        const inner = value
            .map((item) => renderValue(item, indent + "\t"))
            .join("\n");
        return `${indent}<array>\n${inner}\n${indent}</array>`;
    }
    // object
    return renderDict(value, indent);
}
function renderDict(obj, indent) {
    const keys = Object.keys(obj);
    if (keys.length === 0) {
        return `${indent}<dict/>`;
    }
    const inner = keys
        .map((key) => {
        const keyLine = `${indent}\t<key>${escapeXml(key)}</key>`;
        const valueLine = renderValue(obj[key], indent + "\t");
        return `${keyLine}\n${valueLine}`;
    })
        .join("\n");
    return `${indent}<dict>\n${inner}\n${indent}</dict>`;
}
function buildPlist(root) {
    return [
        '<?xml version="1.0" encoding="UTF-8"?>',
        DOCTYPE,
        '<plist version="1.0">',
        renderDict(root, ""),
        "</plist>",
        "",
    ].join("\n");
}
