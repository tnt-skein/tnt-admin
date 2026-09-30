// Сборка панели: SCSS → CSS и модули → один сценарий.
//
// Страницы здесь не собираются: их рисует узел шаблонизатором, и в сборку
// идёт только то, что уходит в браузер файлом, — оформление и сценарий.
//
// Собранное кладётся в panel/, а оттуда пакуется в модуль Lua
// (`make panel`): узел раздаёт панель из памяти процесса, и ни
// отдельного веб-сервера для статики, ни расхождения версий панели
// и узла быть не может.
//
// Отпечатков в именах и манифеста здесь нет намеренно, в отличие
// от сборки приложения: файлов три, отдаёт их сам узел, и версия панели
// меняется вместе с версией пакета.
//
//   bun run build    разовая сборка
//   bun run watch    пересборка при правке ui/

import { watch } from 'node:fs';
import { mkdir, readdir, writeFile, unlink } from 'node:fs/promises';
import { join } from 'node:path';

/** Корень пакета: сценарий лежит в scripts/. */
const ROOT = join(import.meta.dir, '..');

/** Исходники панели. */
const SOURCE_DIR = join(ROOT, 'ui');

/** Куда кладётся собранное: этот каталог и пакуется в модуль. */
const OUT_DIR = join(ROOT, 'panel');

/** Сколько ждать тишины после правки, мс: редактор пишет файл несколькими событиями. */
const SETTLE_MS = 100;

/**
 * Собирает стили: dart-sass поверх исходников Bootstrap из node_modules.
 *
 * Пакет грузится по требованию, а не сверху файла: сборка стилей нужна
 * не каждому запуску.
 *
 * @returns {Promise<string>} готовый CSS
 */
async function buildStyles() {
    const sass = await import('sass');

    const result = sass.compile(join(SOURCE_DIR, 'styles', 'panel.scss'), {
        // `@import 'bootstrap/scss/…'` ищется здесь: путь пакета и есть путь файла.
        loadPaths: [join(ROOT, 'node_modules')],
        style: 'compressed',
        // Карты исходников панели не нужны: она отдаётся из памяти узла,
        // и файла рядом, на который карта ссылается, нет.
        sourceMap: false,
    });

    return result.css;
}

/**
 * Собирает сценарий: модули панели и Bootstrap в один файл.
 *
 * @returns {Promise<string>} готовый JS
 */
async function buildScript() {
    const result = await Bun.build({
        entrypoints: [join(SOURCE_DIR, 'js', 'panel.js')],
        minify: true,
        target: 'browser',
        format: 'iife',
    });

    if (!result.success) {
        throw new AggregateError(result.logs, 'сценарий панели не собран');
    }

    return await result.outputs[0].text();
}

/** Собирает панель целиком. */
async function build() {
    await mkdir(OUT_DIR, { recursive: true });

    // Прежнее собранное убирается целиком: файл, переименованный
    // в исходниках, иначе остался бы в панели и уехал бы в модуль.
    for (const name of await readdir(OUT_DIR)) {
        await unlink(join(OUT_DIR, name));
    }

    await writeFile(join(OUT_DIR, 'panel.css'), await buildStyles());
    await writeFile(join(OUT_DIR, 'panel.js'), await buildScript());

    console.log('Панель собрана: panel.css, panel.js');
}

await build();

if (process.argv.includes('--watch')) {
    let timer = null;

    watch(SOURCE_DIR, { recursive: true }, () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
            build().catch((failure) => console.error(failure.message));
        }, SETTLE_MS);
    });

    console.log('Жду правок в ui/…');
}
