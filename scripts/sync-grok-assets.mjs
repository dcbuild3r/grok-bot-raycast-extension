import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import ts from "typescript";

const root = fileURLToPath(new URL("../", import.meta.url));
const app = [
  "/Applications/Grok Bot.app",
  path.join(os.homedir(), "Applications/Grok Bot.app"),
].find((candidate) =>
  fs.existsSync(path.join(candidate, "Contents/Resources/app.asar")),
);
if (!app)
  throw new Error(
    "Install Grok Bot in Applications before building the extension.",
  );
const archive = path.join(app, "Contents/Resources/app.asar");
const fd = fs.openSync(archive, "r");
const prefix = Buffer.alloc(16);
fs.readSync(fd, prefix, 0, 16, 0);
const base = 8 + prefix.readUInt32LE(4);
const headerBytes = Buffer.alloc(prefix.readUInt32LE(12));
fs.readSync(fd, headerBytes, 0, headerBytes.length, 16);
const header = JSON.parse(headerBytes.toString("utf8"));
const files = header.files.dist.files.renderer.files.assets.files;
function readAsset(name) {
  if (path.basename(name) !== name || !files[name] || files[name].unpacked)
    throw new Error(`Unsupported Grok asset ${name}`);
  const entry = files[name];
  const data = Buffer.alloc(entry.size);
  fs.readSync(fd, data, 0, data.length, base + Number(entry.offset));
  return data.toString("utf8");
}
function writeChanged(file, data) {
  const bytes = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (!fs.existsSync(file) || !fs.readFileSync(file).equals(bytes))
    fs.writeFileSync(file, bytes);
}
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "grok-raycast-assets-"));
try {
  fs.writeFileSync(path.join(temp, "package.json"), '{"type":"module"}');
  const copied = new Set();
  function copyModule(name) {
    if (copied.has(name)) return;
    copied.add(name);
    const code = readAsset(name);
    const source = ts.createSourceFile(
      name,
      code,
      ts.ScriptTarget.ESNext,
      true,
    );
    for (const statement of source.statements) {
      if (!ts.isImportDeclaration(statement)) continue;
      const dependency = statement.moduleSpecifier.text;
      if (!dependency.startsWith("./") || dependency.slice(2).includes("/"))
        throw new Error("The installed Grok Bot asset format changed.");
      copyModule(dependency.slice(2));
    }
    fs.writeFileSync(path.join(temp, name), code);
  }
  const commonName = Object.keys(files).find((name) =>
    /^index\.eager-common-.*\.js$/.test(name),
  );
  const platformName = Object.keys(files).find((name) =>
    /^index\.eager-platform-.*\.js$/.test(name),
  );
  if (!commonName || !platformName)
    throw new Error("This Grok Bot build uses an unsupported avatar format.");
  copyModule(commonName);
  const platformFile = path.join(temp, platformName);
  fs.writeFileSync(platformFile, readAsset(platformName));
  const program = ts.createProgram([platformFile], {
    allowJs: true,
    noEmit: true,
    noLib: true,
    target: ts.ScriptTarget.ESNext,
  });
  const source = program.getSourceFile(platformFile);
  const checker = program.getTypeChecker();
  const entry = source.statements.find(
    (node) =>
      ts.isFunctionDeclaration(node) &&
      node.parameters.some((parameter) =>
        parameter.getText(source).includes("grok-bot-still"),
      ),
  );
  if (!entry?.name)
    throw new Error("Grok Bot’s avatar renderer could not be located.");
  const required = new Set();
  const imports = new Map();
  function collect(statement) {
    if (required.has(statement)) return;
    required.add(statement);
    function visit(node) {
      if (ts.isIdentifier(node)) {
        for (const declaration of checker.getSymbolAtLocation(node)
          ?.declarations ?? []) {
          if (declaration.getSourceFile() !== source) continue;
          if (ts.isImportSpecifier(declaration)) {
            if (
              declaration.parent.parent.parent.moduleSpecifier.text !==
              `./${commonName}`
            )
              throw new Error("Unsupported avatar renderer dependency.");
            imports.set(
              declaration.name.text,
              declaration.propertyName?.text ?? declaration.name.text,
            );
            continue;
          }
          let top = declaration;
          while (top.parent && top.parent !== source) top = top.parent;
          if (
            top.parent === source &&
            top !== statement &&
            !ts.isImportDeclaration(top) &&
            !ts.isExportDeclaration(top)
          )
            collect(top);
        }
      }
      ts.forEachChild(node, visit);
    }
    visit(statement);
  }
  collect(entry);
  const code =
    [...imports]
      .map(
        ([local, exported]) =>
          `const ${local}=common[${JSON.stringify(exported)}];`,
      )
      .join("\n") +
    "\n" +
    [...required]
      .sort((a, b) => a.pos - b.pos)
      .map((node) => node.getText(source))
      .join("\n") +
    `\nreturn ${entry.name.text};`;
  const common = await import(pathToFileURL(path.join(temp, commonName)).href);
  // This runs only the installed, trusted Grok Bot renderer to export its own artwork locally.
  const render = new Function("common", code)(common);
  // Minified export names vary between Grok Bot builds.
  const bodyOf = Object.values(common).find(
    (value) =>
      typeof value === "function" &&
      ["starFlower", "heartChubby"].every((name) =>
        String(value).includes(name),
      ),
  );
  if (!bodyOf)
    throw new Error("This Grok Bot build uses an unsupported avatar format.");
  const shapes = [
    "blob",
    "pebble",
    "bean",
    "egg",
    "squircle",
    "tablet",
    "capsule",
    "cylinder",
    "hex",
    "gem",
    "crystal",
    "wedge",
    "shield",
    "dome",
    "arch",
    "cloud",
    "teardrop",
    "leaf",
    "square",
    "sparkle",
    "clover",
    "flower",
    "heart",
    "house",
    "star",
    "pumpkin",
  ];
  const folder = path.join(root, "assets/bot-avatars");
  fs.mkdirSync(folder, { recursive: true });
  for (const shape of shapes) {
    const svg = render({ body: bodyOf(shape), ink: "#ffffff", size: 64 });
    if (!svg.startsWith("<svg") || /NaN|undefined/.test(svg))
      throw new Error(`Invalid Grok Bot avatar ${shape}`);
    writeChanged(path.join(folder, `${shape}.svg`), svg);
  }
  const iconset = path.join(temp, "Grok.iconset");
  execFileSync(
    "/usr/bin/iconutil",
    [
      "--convert",
      "iconset",
      "--output",
      iconset,
      path.join(app, "Contents/Resources/icon.icns"),
    ],
    { stdio: "pipe" },
  );
  const icons = fs
    .readdirSync(iconset)
    .filter((name) => name.endsWith(".png"))
    .sort(
      (a, b) =>
        fs.statSync(path.join(iconset, b)).size -
        fs.statSync(path.join(iconset, a)).size,
    );
  const icon = path.join(temp, "icon.png");
  execFileSync(
    "/usr/bin/sips",
    ["-z", "512", "512", path.join(iconset, icons[0]), "--out", icon],
    { stdio: "pipe" },
  );
  writeChanged(
    path.join(root, "assets/grok-bot-icon.png"),
    fs.readFileSync(icon),
  );
  console.log("Prepared Grok Bot artwork from the installed app.");
} finally {
  fs.closeSync(fd);
  fs.rmSync(temp, { recursive: true, force: true });
}
