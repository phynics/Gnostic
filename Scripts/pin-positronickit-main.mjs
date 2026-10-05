#!/usr/bin/env node

// Rewrites the PositronicKit dependency in Package.swift to track a moving
// branch instead of the released pin. The nightly workflow calls this so it can
// build and test Gnostic against upstream head before a release pins it. It is
// idempotent and never touches any other dependency.
//
//   node Scripts/pin-positronickit-main.mjs [branch] [package.swift path]
//
// Printing the rewritten declaration makes workflow logs show the exact ref
// under test.

import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const branch = process.argv[2] ?? "main";
const packagePath = resolve(process.argv[3] ?? "Package.swift");

const dependencyPattern =
    /\.package\(url: "https:\/\/github\.com\/phynics\/PositronicKit\.git",\s*(?:exact|branch|revision): "[^"]+"\)/;
const replacement = `.package(url: "https://github.com/phynics/PositronicKit.git", branch: "${branch}")`;

const swiftPackage = readFileSync(packagePath, "utf8");
if (!dependencyPattern.test(swiftPackage)) {
    console.error(`${packagePath}: no PositronicKit dependency to rewrite`);
    process.exit(1);
}

const rewritten = swiftPackage.replace(dependencyPattern, replacement);
if (rewritten !== swiftPackage) writeFileSync(packagePath, rewritten);
console.log(replacement);
