#!/usr/bin/env node
// schemas/*.schema.json から TypeScript 型を生成する。
// あわせて JSON Schema 本体を TS の const として埋め込んだ schemas.ts を出す。
// JSON を直接 import すると ESM の import assertions や resolveJsonModule の設定差で
// web / functions のどちらかが必ず壊れるため、生成時に文字列として畳み込んでしまう。

import { compileFromFile } from 'json-schema-to-typescript';
import { readdir, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const schemaDir = join(root, 'schemas');
const outDir = join(root, 'src', 'generated');

/** daily.schema.json -> daily */
const stem = (f) => basename(f, '.schema.json');
/** sleep-session -> SleepSession */
const pascal = (s) => s.replace(/(^|-)(\w)/g, (_, __, c) => c.toUpperCase());

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

const files = (await readdir(schemaDir)).filter((f) => f.endsWith('.schema.json')).sort();
if (files.length === 0) throw new Error(`スキーマが見つかりません: ${schemaDir}`);

const moduleNames = [];
const schemaConsts = [];

for (const file of files) {
  const name = stem(file);
  const ts = await compileFromFile(join(schemaDir, file), {
    bannerComment:
      `/* eslint-disable */\n` +
      `/**\n * 自動生成ファイル — 直接編集しないこと。\n` +
      ` * 生成元: packages/schema/schemas/${file}\n` +
      ` * 再生成: npm run gen:types\n */`,
    additionalProperties: false,
    style: { singleQuote: true },
    cwd: schemaDir,
  });
  await writeFile(join(outDir, `${name}.ts`), ts);
  moduleNames.push(name);

  const raw = JSON.parse(await readFile(join(schemaDir, file), 'utf8'));
  schemaConsts.push(
    `export const ${pascal(name)}Schema = ${JSON.stringify(raw, null, 2)} as const;`,
  );
  console.log(`  ts   ${name}.ts`);
}

const index =
  `/* eslint-disable */\n/** 自動生成ファイル — 直接編集しないこと。再生成: npm run gen:types */\n\n` +
  moduleNames.map((n) => `export * from './${n}';`).join('\n') +
  `\nexport * from './schemas';\n`;
await writeFile(join(outDir, 'index.ts'), index);

const schemasTs =
  `/* eslint-disable */\n` +
  `/**\n * 自動生成ファイル — 直接編集しないこと。再生成: npm run gen:types\n` +
  ` * JSON Schema 本体。実行時バリデーションと Gemini の responseSchema 生成に使う。\n */\n\n` +
  schemaConsts.join('\n\n') +
  '\n';
await writeFile(join(outDir, 'schemas.ts'), schemasTs);

console.log(`✓ TypeScript 型を生成しました (${files.length} スキーマ) -> src/generated/`);
