#!/usr/bin/env node
/**
 * =============================================================================
 * 课晓 · 生成 DevEco/hvigor 能识别的加密签名密码
 * -----------------------------------------------------------------------------
 * 为什么需要它？
 *   build-profile.json5 里的 storePassword / keyPassword **不能填明文**。
 *   hvigor 的签名插件用 AES-128-GCM 加密这两项，明文会直接报错：
 *       The length of the storePassword or keyPassword field ... is less than 32
 *
 *   解密流程（来自 hvigor-ohos-plugin 的 DecipherUtil）：
 *     1) 密钥材料放在「keystore 文件所在目录」下的 material/{fd,ac,ce}/ 里
 *     2) rootKey = PBKDF2-SHA256(XOR(fd0,fd1,fd2,固定组件) 的十进制串, salt, 10000 次, 16 字节)
 *     3) 真正的 AES 密钥 = AES-128-GCM 解密(material/ce 里的内容, rootKey)
 *     4) 密码 = AES-128-GCM 解密(配置里的十六进制串, 上一步的密钥)
 *
 *   所以只要我们自己造 material/ 并按同样格式加密，hvigor 就能读出来。
 *   DevEco Studio 的 Project Structure 页面本质上做的也是这件事。
 *
 * 用法：
 *   # 自检（默认，确认算法与当前 DevEco 版本一致）
 *   node tools/dev/hvigor-signing-pwd.mjs --verify
 *
 *   # 生成：为 <keystore 所在目录> 造 material/ 并输出加密后的密码
 *   node tools/dev/hvigor-signing-pwd.mjs <明文密码> <keystore所在目录>
 *
 * =============================================================================
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

/** hvigor 里的固定异或组件（DecipherUtil.component） */
const COMPONENT = new Int8Array([49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119]);
const DIRS = ['fd', 'ac', 'ce'];

const DEVECO_HOME = process.env.DEVECO_HOME || 'G:/DevEco Studio';
const PLUGIN_RES = path.join(DEVECO_HOME, 'tools/hvigor/hvigor-ohos-plugin/res');

// ---------------------------------------------------------------- 解密（严格照抄插件实现）
function decryptData(key, data) {
  const ivLen = ((255 & data[0]) << 24) | ((255 & data[1]) << 16) | ((255 & data[2]) << 8) | (255 & data[3]);
  const remain = data.length - 4 - ivLen;
  const iv = data.slice(4, 4 + remain);
  const d = crypto.createDecipheriv('aes-128-gcm', key, iv);
  d.setAuthTag(data.slice(data.length - 16));
  return Buffer.concat([d.update(data.subarray(4 + remain, data.length - 16)), d.final()]);
}

// ---------------------------------------------------------------- 加密（解密器的严格逆运算）
// 布局：[4B 大端 = 密文长度+16][IV 12B][密文][GCM tag 16B]
function encryptData(key, plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-128-gcm', key, iv);
  const ct = Buffer.concat([c.update(plain), c.final()]);
  const header = Buffer.alloc(4);
  header.writeUInt32BE(ct.length + 16, 0);
  return Buffer.concat([header, iv, ct, c.getAuthTag()]);
}

// ---------------------------------------------------------------- 从 material 目录推导密钥
function deriveKey(materialDir, label) {
  const base = path.join(materialDir, 'material');
  // fd：三个子目录，各含一个 16 字节文件
  const fdDir = path.join(base, DIRS[0]);
  const fdNames = fs.readdirSync(fdDir).filter((n) => n !== '.DS_Store');
  if (fdNames.length !== 3) throw new Error(`${fdDir} 下应恰好有 3 个子目录，实际 ${fdNames.length}`);
  const fds = fdNames.map((n) => readOneFile(path.join(fdDir, n), label));

  // ac：盐；ce：被包裹的 AES 工作密钥
  const salt = readOneFile(path.join(base, DIRS[1]), label);
  const wrapped = readOneFile(path.join(base, DIRS[2]), label);

  const rootKey = crypto.pbkdf2Sync(xorSeed(fds), salt, 10000, 16, 'sha256');
  return decryptData(rootKey, wrapped);
}

/**
 * PBKDF2 的口令 = XOR(fd0,fd1,fd2,组件) 这 16 个字节【按 UTF-8 解读】得到的字符串。
 * 注意：hvigor 里 xorComponents 返回的是 Buffer，Buffer.toString() 默认走 UTF-8，
 * 不是 Int8Array 那种逗号分隔的数字串 —— 这是最容易搞错的一步。
 */
function xorSeed(fds) {
  const xored = Buffer.alloc(16);
  for (const part of [...fds, Buffer.from(COMPONENT.map((v) => v & 0xff))]) {
    if (part.length !== 16) throw new Error('fd / component 必须都是 16 字节');
    for (let i = 0; i < 16; i++) xored[i] ^= part[i];
  }
  return xored.toString('utf8');
}

function readOneFile(dir, label) {
  const names = fs.readdirSync(dir).filter((n) => n !== '.DS_Store');
  if (names.length !== 1) throw new Error(`${dir} 下应恰好有 1 个文件（${label}），实际 ${names.length}`);
  return fs.readFileSync(path.join(dir, names[0]));
}

// ---------------------------------------------------------------- material 目录生成
/** XOR 后 PBKDF2 的口令，挑成可读 ASCII，避免 UTF-8 解码出现替换字符带来歧义 */
const SEED_TEXT = 'kexiao.sig.local';

function writeMaterial(materialDir) {
  const base = path.join(materialDir, 'material');
  fs.rmSync(base, { recursive: true, force: true });
  fs.mkdirSync(base, { recursive: true });

  // fd 三个 16 字节块：让 fd1=fd2=0，把目标种子"塞"进 fd0，XOR 后正好得到 SEED_TEXT
  const target = Buffer.from(SEED_TEXT, 'utf8');
  const compBuf = Buffer.from(COMPONENT.map((v) => v & 0xff));
  const fd0 = Buffer.alloc(16);
  for (let i = 0; i < 16; i++) fd0[i] = target[i] ^ compBuf[i];
  const fds = [fd0, Buffer.alloc(16), Buffer.alloc(16)];
  fds.forEach((buf, i) => {
    const d = path.join(base, DIRS[0], String(i));
    fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(d, 'k'), buf);
  });
  const salt = crypto.randomBytes(16);
  fs.mkdirSync(path.join(base, DIRS[1]), { recursive: true });
  fs.writeFileSync(path.join(base, DIRS[1], 's'), salt);

  // 用与读取端同一个推导函数算出 rootKey，再随机一个工作密钥包进 ce
  const rootKey = crypto.pbkdf2Sync(xorSeed(fds), salt, 10000, 16, 'sha256');
  const workKey = crypto.randomBytes(16);
  fs.mkdirSync(path.join(base, DIRS[2]), { recursive: true });
  fs.writeFileSync(path.join(base, DIRS[2], 'w'), encryptData(rootKey, workKey));

  return workKey;
}

// ---------------------------------------------------------------- 自检
function verify() {
  const zb = path.join(PLUGIN_RES, 'material/zb/de');
  if (!fs.existsSync(zb)) {
    console.log('⚠ 找不到 DevEco 自带的材料，跳过自检：' + zb);
    return;
  }
  const key = deriveKey(PLUGIN_RES, 'verify');
  const got = decryptData(key, Buffer.from(fs.readFileSync(zb, 'utf8').trim(), 'hex')).toString('utf8');
  // hvigor 里 KeyStoreHelper.DEFAULT_STORE_PASS 的明文就是 DebugKey
  if (got !== 'DebugKey') {
    console.error(`✗ 自检失败：解出 "${got}"，期望 "DebugKey"。当前 DevEco 版本可能改了加密方式。`);
    process.exit(1);
  }
  // 再验一遍「加密 → 解密」闭环
  const probe = encryptData(key, Buffer.from('123456'));
  const back = decryptData(key, probe).toString('utf8');
  if (back !== '123456') {
    console.error(`✗ 加解密闭环失败：得到 "${back}"`);
    process.exit(1);
  }
  console.log('✓ 自检通过：密钥推导与加解密格式和当前 DevEco 一致');
}

// ---------------------------------------------------------------- 入口
const [, , arg1, arg2] = process.argv;
if (!arg1 || arg1 === '--verify') {
  verify();
} else if (arg1.startsWith('--')) {
  console.error('用法：node tools/dev/hvigor-signing-pwd.mjs [--verify | <明文密码> <keystore所在目录>]');
  process.exit(2);
} else {
  if (!arg2) {
    console.error('缺少参数：<keystore所在目录>');
    process.exit(2);
  }
  const plain = arg1;
  const materialDir = path.resolve(arg2);
  if (!fs.existsSync(materialDir)) fs.mkdirSync(materialDir, { recursive: true });
  const workKey = writeMaterial(materialDir);
  const encrypted = encryptData(workKey, Buffer.from(plain, 'utf8')).toString('hex');
  // 用自己刚写的 material 反解一次，确认写进配置的值真能被读出来
  const check = decryptData(deriveKey(materialDir, 'check'), Buffer.from(encrypted, 'hex')).toString('utf8');
  if (check !== plain) {
    console.error('✗ 生成后校验失败');
    process.exit(1);
  }
  console.log('✓ material 已写入：' + path.join(materialDir, 'material'));
  console.log('✓ 加密后的密码（填进 build-profile.json5）：');
  console.log(encrypted);
}
