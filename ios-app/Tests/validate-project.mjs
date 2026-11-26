import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
// 小型 OpenStep property-list 读取器，检查工程对象/文件引用；不冒充 Xcode 编译。
const tokens = read('IfengAdmin.xcodeproj/project.pbxproj').replace(/^\/\/.*$/gm, '')
  .match(/"(?:[^"\\]|\\.)*"|[{}()=;,]|[^\s{}()=;,]+/g);
let cursor = 0;
const peek = () => tokens[cursor];
function take(expected) {
  const token = tokens[cursor++];
  if (expected) assert.equal(token, expected);
  return token;
}
function value() {
  if (peek() === '{') {
    take('{'); const result = {};
    while (peek() !== '}') {
      const key = scalar(take()); take('='); result[key] = value(); take(';');
    }
    take('}'); return result;
  }
  if (peek() === '(') {
    take('('); const result = [];
    while (peek() !== ')') { result.push(value()); if (peek() !== ')') take(','); }
    take(')'); return result;
  }
  return scalar(take());
}
const scalar = token => token.startsWith('"') ? JSON.parse(token) : token;
const pbx = value();
assert.equal(cursor, tokens.length);
const objects = pbx.objects;
assert.equal(objects[pbx.rootObject].isa, 'PBXProject');
const byType = type => Object.values(objects).filter(object => object.isa === type);
const swiftFiles = [];
function walk(directory) {
  for (const entry of fs.readdirSync(directory, {withFileTypes:true})) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(file);
    else if (file.endsWith('.swift')) swiftFiles.push(path.relative(root, file).replaceAll('\\','/'));
  }
}
walk(path.join(root, 'IfengAdmin'));
const sourceRefs = byType('PBXSourcesBuildPhase').flatMap(phase => phase.files.map(id => objects[objects[id].fileRef].path));
assert.deepEqual(sourceRefs.sort(), swiftFiles.sort());
for (const ref of byType('PBXFileReference').filter(ref => ref.sourceTree === 'SOURCE_ROOT')) {
  assert.ok(fs.existsSync(path.join(root, ref.path)), `Missing project file: ${ref.path}`);
}
for (const object of Object.values(objects)) {
  for (const key of ['fileRef','mainGroup','buildConfigurationList','productReference','baseConfigurationReference']) {
    if (object[key]) assert.ok(objects[object[key]], `Unresolved ${key}`);
  }
  for (const key of ['children','buildPhases','buildConfigurations','targets','files']) {
    for (const id of object[key] || []) assert.ok(objects[id], `Unresolved ${key}: ${id}`);
  }
}
assert.equal(byType('PBXNativeTarget').length, 1);
const scheme = read('IfengAdmin.xcodeproj/xcshareddata/xcschemes/IfengAdmin.xcscheme');
assert.ok(scheme.includes('BlueprintIdentifier="A00000000000000000000001"'));
const bridge = read('IfengAdmin/Resources/AdminBridge.js');
assert.equal(bridge.split('__ADMIN_ORIGIN__').length, 2);
new vm.Script(bridge.replace('__ADMIN_ORIGIN__', '"https://support.example.com"'));
const resources = byType('PBXResourcesBuildPhase').flatMap(phase => phase.files.map(id => objects[objects[id].fileRef].path));
assert.ok(resources.includes('IfengAdmin/Resources/AdminBridge.js'));
assert.ok(resources.includes('IfengAdmin/Resources/Assets.xcassets'));
const icon = fs.readFileSync(path.join(root,'IfengAdmin/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'));
assert.equal(icon.readUInt32BE(16),1024); assert.equal(icon.readUInt32BE(20),1024);
assert.equal(read('IfengAdmin/Info.plist').includes('NSAllowsArbitraryLoads</key><true'),false);
assert.equal(read('Configuration/App.xcconfig').includes('IPHONEOS_DEPLOYMENT_TARGET = 16.0'),true);

// Actions 自定义输入校验；不允许用户名密码、路径、任意 shell 字符混入设置。
if (process.env.ADMIN_INPUT) {
  const url = new URL(process.env.ADMIN_INPUT);
  assert.ok(url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash && url.pathname === '/');
  assert.ok(!/[\r\n\s]/.test(process.env.ADMIN_INPUT));
}
if (process.env.BUNDLE_INPUT) assert.match(process.env.BUNDLE_INPUT, /^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+$/);
if (process.env.SCHEME_INPUT) {
  assert.match(process.env.SCHEME_INPUT, /^[a-z][a-z0-9+.-]*$/);
  assert.ok(!['https','http','javascript','data','file'].includes(process.env.SCHEME_INPUT));
}
console.log(`Project checks passed: ${swiftFiles.length} Swift sources, ${Object.keys(objects).length} objects, resources and shared scheme`);
