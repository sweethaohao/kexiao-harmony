/**
 * 课晓 · 逻辑自测运行器
 * ---------------------------------------------------------------------------
 * 做的事：
 *   1. 把 entry/src/main/ets 下的"纯逻辑" .ets 文件复制到 .build/ 并改名为 .ts；
 *   2. 把 `import { A } from '../model/Models'` 这类路径拍平成 `'./Models.ts'`；
 *   3. 把纯类型（interface / type）的导入拆成 `import type`，
 *      因为 Node 的类型擦除是"逐文件"的，运行时找不到纯类型的导出会报错；
 *   4. 用 Node 直接跑 cases.ts（Node 22 内置 TypeScript 类型擦除，无需安装依赖）。
 *
 * 用法：node tools/selftest/run.mjs
 * ---------------------------------------------------------------------------
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, '..', '..');
const etsRoot = path.join(projectRoot, 'entry', 'src', 'main', 'ets');
const buildDir = path.join(here, '.build');

/** 需要搬运的纯逻辑模块（相对 ets 根目录） */
const MODULES = [
  'model/Models.ets',
  'model/Defaults.ets',
  'common/DateUtil.ets',
  'common/SlotTimeTable.ets',
  'service/ScheduleService.ets',
  'service/ImportService.ets'
];

/** 收集某个模块里所有"纯类型"导出的名字 */
function collectTypeNames(source) {
  const names = new Set();
  const re = /export\s+(?:interface|type)\s+([A-Za-z0-9_]+)/g;
  let m;
  while ((m = re.exec(source)) !== null) {
    names.add(m[1]);
  }
  return names;
}

/** 把 import 语句按"值是值、类型是类型"拆成两条 */
function rewriteImports(source, typeNamesByModule, warn) {
  return source.replace(
    /import\s*\{([^}]*)\}\s*from\s*'([^']+)';?/g,
    (whole, nameList, spec) => {
      const moduleName = spec.split('/').pop();
      const types = typeNamesByModule.get(moduleName);
      if (types === undefined) {
        warn(`找不到模块 ${moduleName}（来自 ${spec}）`);
        return whole;
      }
      const values = [];
      const onlyTypes = [];
      for (const raw of nameList.split(',')) {
        const name = raw.trim();
        if (name.length === 0) {
          continue;
        }
        if (types.has(name)) {
          onlyTypes.push(name);
        } else {
          values.push(name);
        }
      }
      const lines = [];
      if (values.length > 0) {
        lines.push(`import { ${values.join(', ')} } from './${moduleName}.ts';`);
      }
      if (onlyTypes.length > 0) {
        lines.push(`import type { ${onlyTypes.join(', ')} } from './${moduleName}.ts';`);
      }
      return lines.length > 0 ? lines.join('\n') : '';
    }
  );
}

function main() {
  const problems = [];
  const warn = (msg) => problems.push(msg);

  // ---- 1. 读取所有模块，收集类型名 ----
  const sources = new Map();
  const typeNamesByModule = new Map();
  for (const rel of MODULES) {
    const abs = path.join(etsRoot, rel);
    if (!fs.existsSync(abs)) {
      console.error(`缺少源文件：${abs}`);
      process.exit(1);
    }
    const text = fs.readFileSync(abs, 'utf8');
    const base = path.basename(rel, '.ets');
    sources.set(base, text);
    typeNamesByModule.set(base, collectTypeNames(text));
  }

  // ---- 2. 清空并重建 .build ----
  fs.rmSync(buildDir, { recursive: true, force: true });
  fs.mkdirSync(buildDir, { recursive: true });

  // ---- 3. 写转换后的模块 ----
  for (const [base, text] of sources) {
    const converted = rewriteImports(text, typeNamesByModule, warn);
    fs.writeFileSync(path.join(buildDir, `${base}.ts`), converted, 'utf8');
  }

  // ---- 4. 把「示例课表」JSON 作为 fixture 注入（避免测试里写死长 JSON） ----
  // 读的是随包分发的虚构示例数据；真实课表放在工程外，永不入库、永不进包。
  const jsonPath = path.join(
    projectRoot, 'entry', 'src', 'main', 'resources', 'rawfile', 'sample-schedule.json');
  if (!fs.existsSync(jsonPath)) {
    console.error(`缺少示例课表 JSON：${jsonPath}`);
    process.exit(1);
  }
  const jsonText = fs.readFileSync(jsonPath, 'utf8');
  fs.writeFileSync(
    path.join(buildDir, 'fixture.ts'),
    `export const SCHEDULE_JSON_TEXT: string = ${JSON.stringify(jsonText)};\n`,
    'utf8'
  );

  // ---- 5. 转换测试用例本身 ----
  // fixture 里全是值，没有纯类型
  typeNamesByModule.set('fixture', new Set());
  const casesPath = path.join(here, 'cases.ts');
  const casesText = fs.readFileSync(casesPath, 'utf8');
  const casesConverted = rewriteImports(casesText, typeNamesByModule, warn);
  fs.writeFileSync(path.join(buildDir, 'cases.ts'), casesConverted, 'utf8');

  if (problems.length > 0) {
    console.log('转换期提示：');
    for (const p of problems) {
      console.log(`  · ${p}`);
    }
  }

  // ---- 6. 跑测试 ----
  const entry = pathToFileURL(path.join(buildDir, 'cases.ts')).href;
  console.log(`运行自测：${path.relative(projectRoot, casesPath)}`);
  return import(entry);
}

await main();
