#!/usr/bin/env node
// schemas/*.schema.json から Dart クラスを生成して app/lib/models/generated/ に置く。
//
// quicktype は --top-level を 1 回しか受け付けないため、スキーマ 1 つにつき 1 ファイルを生成し、
// generated.dart というバレルからまとめて export する。
// ネストしたクラス名がスキーマ間で衝突すると、バレルを import した時点で
// Dart のコンパイルエラーになるので、黙って壊れることはない。

import { spawn } from 'node:child_process';
import { readdir, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = join(root, '..', '..');
const schemaDir = join(root, 'schemas');
const outDir = join(repoRoot, 'app', 'lib', 'models', 'generated');
const quicktype = join(repoRoot, 'node_modules', '.bin', 'quicktype');

/** daily.schema.json -> daily_summary.dart のような snake_case ファイル名 */
const snake = (s) => s.replace(/-/g, '_');

const run = (args) =>
  new Promise((resolve, reject) => {
    const p = spawn(quicktype, args, { stdio: ['ignore', 'inherit', 'inherit'] });
    p.on('error', reject);
    p.on('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`quicktype が終了コード ${code} で失敗しました`)),
    );
  });

const header = (srcFile) =>
  `// 自動生成ファイル — 直接編集しないこと。\n` +
  `// 生成元: packages/schema/schemas/${srcFile}\n` +
  `// 再生成: npm run gen:types\n` +
  `// ignore_for_file: type=lint, unused_import\n\n`;

const files = (await readdir(schemaDir)).filter((f) => f.endsWith('.schema.json')).sort();
if (files.length === 0) throw new Error(`スキーマが見つかりません: ${schemaDir}`);

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

const generated = [];

for (const file of files) {
  const stem = snake(basename(file, '.schema.json'));
  const outFile = join(outDir, `${stem}.dart`);
  // スキーマの title をトップレベル型名にする。ファイル名から推測しない。
  const { title } = JSON.parse(await readFile(join(schemaDir, file), 'utf8'));
  if (!title) throw new Error(`${file} に title がありません。トップレベル型名を決められません。`);

  await run([
    '--quiet',
    '--src-lang', 'schema',
    '--lang', 'dart',
    '--null-safety',
    '--copy-with',
    '--final-props',
    '--top-level', title,
    '-o', outFile,
  ].concat([join(schemaDir, file)]));

  const body = await readFile(outFile, 'utf8');
  await writeFile(outFile, header(file) + body);
  generated.push({ stem, title });
  console.log(`  dart ${stem}.dart  (${title})`);
}

// バレルを組む前に、ファイルをまたいだトップレベル名の衝突を検出する。
// quicktype は enum を含むスキーマごとに EnumValues<T> ヘルパーを吐くので、
// これだけは重複が正常。2 番目以降の定義を hide して逃がす。
// それ以外の名前が衝突したらスキーマ側の設計ミスなので、黙って隠さず落とす。
const HELPER_TYPES = new Set(['EnumValues']);
const seen = new Map(); // 型名 -> 最初に定義したファイル
const exportLines = [];

for (const { stem } of generated) {
  const src = await readFile(join(outDir, `${stem}.dart`), 'utf8');
  const names = [...src.matchAll(/^(?:class|enum)\s+(\w+)/gm)].map((m) => m[1]);
  const hide = [];

  for (const name of names) {
    const owner = seen.get(name);
    if (owner === undefined) {
      seen.set(name, stem);
    } else if (HELPER_TYPES.has(name)) {
      hide.push(name);
    } else {
      throw new Error(
        `型名 ${name} が ${owner}.dart と ${stem}.dart で衝突しています。` +
          `どちらかのスキーマでプロパティ名を変えるか、共通定義に切り出してください。`,
      );
    }
  }

  exportLines.push(
    hide.length > 0
      ? `export '${stem}.dart' hide ${[...new Set(hide)].join(', ')};`
      : `export '${stem}.dart';`,
  );
}

const barrel =
  `// 自動生成ファイル — 直接編集しないこと。\n` +
  `// 再生成: npm run gen:types\n\n` +
  exportLines.join('\n') +
  '\n';
await writeFile(join(outDir, 'generated.dart'), barrel);

console.log(`✓ Dart モデルを生成しました (${files.length} スキーマ) -> app/lib/models/generated/`);
