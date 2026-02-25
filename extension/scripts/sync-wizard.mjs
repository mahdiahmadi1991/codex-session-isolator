import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const sourcePath = path.resolve(__dirname, "../../tools/vsc-launcher-wizard.ps1");
const targetPath = path.resolve(__dirname, "./vsc-launcher-wizard.ps1");

if (!fs.existsSync(sourcePath)) {
  console.error(`[sync] Source wizard not found: ${sourcePath}`);
  process.exit(1);
}

const sourceContent = fs.readFileSync(sourcePath);
const hasTarget = fs.existsSync(targetPath);
const targetContent = hasTarget ? fs.readFileSync(targetPath) : null;

if (!hasTarget || !sourceContent.equals(targetContent)) {
  fs.copyFileSync(sourcePath, targetPath);
  console.log(`[sync] Updated bundled wizard: ${path.basename(targetPath)}`);
} else {
  console.log("[sync] Bundled wizard already up to date.");
}
