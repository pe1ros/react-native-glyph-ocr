#!/usr/bin/env node
/**
 * Builds models/manifest.json and the recognizer dictionaries in models/pp-ocrv5/ from the official
 * PaddlePaddle ONNX exports on Hugging Face, pinned to the current revision of each repository.
 *
 * usage: node scripts/build-manifest.mjs [--check]
 *   --check: rebuild in memory and fail if models/ differs (nothing is written)
 *
 * For every pack it reads the repository's file list (sha256 and size of inference.onnx come from
 * Git LFS), downloads inference.yml and writes its `PostProcess.character_dict` one character per
 * line. Languages follow PaddleOCR's own grouping (paddleocr/_utils/langs.py), as BCP-47 tags;
 * `en` is added to a pack only if its dictionary has every ASCII letter.
 */
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import YAML from 'yaml';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', 'models');
const HF = 'https://huggingface.co';

const DETECTOR = { id: 'pp-ocrv5-det-mobile', repo: 'PaddlePaddle/PP-OCRv5_mobile_det_onnx', path: 'pp-ocrv5/PP-OCRv5_mobile_det.onnx' };
/** PP-OCRv6 has its own, smaller detector (1.8 MB), used by the PP-OCRv6 packs. */
const DETECTOR_V6 = { id: 'pp-ocrv6-tiny-det', repo: 'PaddlePaddle/PP-OCRv6_tiny_det_onnx', path: 'pp-ocrv6/PP-OCRv6_tiny_det.onnx' };

/** Narrow packs first: the first pack covering all requested languages wins. */
const PACKS = [
  { id: 'en', repo: 'en_PP-OCRv5_mobile_rec_onnx', languages: ['en'] },
  { id: 'eslav', repo: 'eslav_PP-OCRv5_mobile_rec_onnx', languages: ['ru', 'uk', 'be'] },
  {
    id: 'cyrillic',
    repo: 'cyrillic_PP-OCRv5_mobile_rec_onnx',
    // PaddleOCR's codes, as BCP-47: rs_cyrillic → sr-Cyrl, ava → av, che → ce; mo (deprecated) is left out.
    languages: [
      'ru', 'uk', 'be', 'sr-Cyrl', 'bg', 'mk', 'mn', 'kk', 'ky', 'tg', 'tt', 'ba', 'cv', 'udm', 'kv',
      'os', 'bua', 'xal', 'tyv', 'sah', 'kaa', 'mhr', 'abq', 'ady', 'kbd', 'av', 'dar', 'inh', 'ce',
      'lbe', 'lez', 'tab',
    ],
  },
  {
    id: 'latin',
    repo: 'latin_PP-OCRv5_mobile_rec_onnx',
    // rs_latin → sr-Latn; ku is in both latin and arabic in PaddleOCR, so the script is explicit.
    languages: [
      'de', 'fr', 'es', 'it', 'pt', 'nl', 'pl', 'cs', 'sk', 'sl', 'hr', 'bs', 'sr-Latn', 'ro', 'hu',
      'sv', 'da', 'no', 'fi', 'et', 'lv', 'lt', 'is', 'ga', 'cy', 'mt', 'sq', 'tr', 'az', 'uz',
      'ku-Latn', 'vi', 'id', 'ms', 'tl', 'sw', 'af', 'mi', 'oc', 'ca', 'eu', 'gl', 'lb', 'rm', 'qu',
      'la', 'pi',
    ],
  },
  { id: 'korean', repo: 'korean_PP-OCRv5_mobile_rec_onnx', languages: ['ko'] },
  { id: 'arabic', repo: 'arabic_PP-OCRv5_mobile_rec_onnx', languages: ['ar', 'fa', 'ur', 'ug', 'ps', 'sd', 'bal', 'ku-Arab'] },
  {
    id: 'devanagari',
    repo: 'devanagari_PP-OCRv5_mobile_rec_onnx',
    languages: ['hi', 'mr', 'ne', 'sa', 'mai', 'bho', 'new', 'gom', 'bh', 'ang', 'mah', 'sck', 'bgc'],
  },
  { id: 'th', repo: 'th_PP-OCRv5_mobile_rec_onnx', languages: ['th'] },
  { id: 'el', repo: 'el_PP-OCRv5_mobile_rec_onnx', languages: ['el'] },
  { id: 'ta', repo: 'ta_PP-OCRv5_mobile_rec_onnx', languages: ['ta'] },
  { id: 'te', repo: 'te_PP-OCRv5_mobile_rec_onnx', languages: ['te'] },
  { id: 'ch', repo: 'PP-OCRv5_mobile_rec_onnx', languages: ['zh-Hans', 'zh-Hant', 'ja'] },
  {
    // PP-OCRv6 tiny: one 4.5 MB multilingual recognizer (6.9k characters). Last, so it is picked
    // only when asked for (paddlePack: 'multi') or when no single PP-OCRv5 pack covers the
    // languages (Chinese with German). Languages: those whose letters are all in its dictionary;
    // no Japanese kana, Korean, Cyrillic, Romanian ș/ț or Vietnamese.
    id: 'multi',
    repo: 'PP-OCRv6_tiny_rec_onnx',
    family: 'PP-OCRv6',
    dir: 'pp-ocrv6',
    detector: DETECTOR_V6,
    languages: [
      'zh-Hans', 'zh-Hant', 'de', 'fr', 'es', 'it', 'pt', 'nl', 'pl', 'cs', 'sk', 'sl', 'hr', 'bs',
      'sr-Latn', 'hu', 'sv', 'da', 'no', 'fi', 'et', 'lv', 'lt', 'is', 'ga', 'cy', 'mt', 'sq', 'tr',
      'ku-Latn', 'id', 'ms', 'tl', 'sw', 'af', 'mi', 'oc', 'ca', 'eu', 'gl', 'lb', 'rm', 'qu', 'la',
    ],
  },
];

async function json(url) {
  const r = await fetch(url);
  if (!r.ok) {
    throw new Error(`${url}: HTTP ${r.status}`);
  }
  return r.json();
}

async function text(url) {
  const r = await fetch(url);
  if (!r.ok) {
    throw new Error(`${url}: HTTP ${r.status}`);
  }
  return r.text();
}

/** The pinned revision and the LFS sha256/size of inference.onnx. */
async function onnxFile(repo) {
  const info = await json(`${HF}/api/models/${repo}`);
  const tree = await json(`${HF}/api/models/${repo}/tree/${info.sha}`);
  const onnx = tree.find(f => f.path === 'inference.onnx');
  if (!onnx?.lfs) {
    throw new Error(`${repo}: no inference.onnx in LFS`);
  }
  return {
    revision: info.sha,
    url: `${HF}/${repo}/resolve/${info.sha}/inference.onnx`,
    sha256: onnx.lfs.oid,
    bytes: onnx.lfs.size,
  };
}

const sha256 = s => createHash('sha256').update(s).digest('hex');

async function build() {
  const outputs = new Map();
  const det = await onnxFile(DETECTOR.repo);
  const detV6 = await onnxFile(DETECTOR_V6.repo);
  const files = [
    {
      id: DETECTOR.id, role: 'detector', format: 'onnx', path: DETECTOR.path,
      url: det.url, sha256: det.sha256, bytes: det.bytes, license: 'Apache-2.0',
    },
    {
      id: DETECTOR_V6.id, role: 'detector', format: 'onnx', path: DETECTOR_V6.path,
      url: detV6.url, sha256: detV6.sha256, bytes: detV6.bytes, license: 'Apache-2.0',
    },
  ];
  const packs = [];
  for (const p of PACKS) {
    const repo = `PaddlePaddle/${p.repo}`;
    const rec = await onnxFile(repo);
    const yml = YAML.parse(await text(`${HF}/${repo}/resolve/${rec.revision}/inference.yml`));
    const chars = yml?.PostProcess?.character_dict;
    if (!Array.isArray(chars) || chars.length === 0) {
      throw new Error(`${repo}: no PostProcess.character_dict`);
    }
    const dict = chars.map(String).join('\n') + '\n';
    const family = p.family ?? 'PP-OCRv5';
    const prefix = family.toLowerCase();
    const name = p.repo.replace(/_onnx$/, '');
    const recPath = `${p.dir ?? 'pp-ocrv5'}/${name}.onnx`;
    const dictPath = `${p.dir ?? 'pp-ocrv5'}/${name}.dict.txt`;
    outputs.set(dictPath, dict);
    const ascii = [...'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'].every(c => chars.includes(c));
    const languages = ascii && !p.languages.includes('en') ? [...p.languages, 'en'] : p.languages;
    files.push(
      {
        id: `${prefix}-rec-${p.id}`, role: 'recognizer', format: 'onnx', path: recPath,
        url: rec.url, sha256: rec.sha256, bytes: rec.bytes, license: 'Apache-2.0',
      },
      {
        // No url: dictionaries are small and always ship inside the package (models/).
        id: `${prefix}-dict-${p.id}`, role: 'dictionary', format: 'dict', path: dictPath,
        sha256: sha256(dict), bytes: Buffer.byteLength(dict), license: 'Apache-2.0',
      },
    );
    packs.push({
      id: p.id, engine: 'paddle', family, languages,
      files: [(p.detector ?? DETECTOR).id, `${prefix}-rec-${p.id}`, `${prefix}-dict-${p.id}`],
    });
    console.error(`${p.id}: ${chars.length} chars, ${(rec.bytes / 1e6).toFixed(1)} MB, ${languages.length} languages`);
  }
  outputs.set('manifest.json', JSON.stringify({ schemaVersion: 1, files, packs }, null, 2) + '\n');
  return outputs;
}

const outputs = await build();
if (process.argv.includes('--check')) {
  const stale = [...outputs].filter(([path, content]) => {
    try {
      return readFileSync(join(ROOT, path), 'utf8') !== content;
    } catch {
      return true;
    }
  });
  if (stale.length) {
    console.error(`stale: ${stale.map(([p]) => p).join(', ')}`);
    process.exit(1);
  }
  console.error('models/ is up to date');
} else {
  for (const [path, content] of outputs) {
    mkdirSync(dirname(join(ROOT, path)), { recursive: true });
    writeFileSync(join(ROOT, path), content);
  }
  console.error(`wrote ${outputs.size} files to ${ROOT}`);
}
