#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function fail(message) {
  console.error(message);
  process.exit(1);
}

function readVersionFromPackage() {
  const packagePath = path.resolve("extension", "package.json");
  const pkg = JSON.parse(fs.readFileSync(packagePath, "utf8"));
  return String(pkg.version || "").trim();
}

const [channel, suppliedVersion] = process.argv.slice(2);
const version = (suppliedVersion || readVersionFromPackage()).trim();

if (channel !== "stable" && channel !== "pre-release") {
  fail("Usage: node ./tools/validate-extension-version-lane.mjs <stable|pre-release> [version]");
}

const match = version.match(/^(\d+)\.(\d+)\.(\d+)$/);
if (!match) {
  fail(
    `Extension version '${version}' is invalid for ${channel}. ` +
      "Use plain semver only (x.y.z) with no suffixes."
  );
}

const patch = Number(match[3]);
const expectsEvenPatch = channel === "stable";
const isEvenPatch = patch % 2 === 0;

if (expectsEvenPatch && !isEvenPatch) {
  fail(
    `Stable channel requires an even patch version. ` +
      `Current version '${version}' is not valid for stable.`
  );
}

if (!expectsEvenPatch && isEvenPatch) {
  fail(
    `Pre-release channel requires an odd patch version. ` +
      `Current version '${version}' is not valid for pre-release.`
  );
}

console.log(`Version lane validated: ${version} is valid for ${channel}.`);
