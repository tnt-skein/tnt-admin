// Сценарий панели: обновлять страницу самой и помнить тему.
//
// Больше ему делать нечего: страницы рисует узел шаблонизатором, отбор —
// это адрес, действие — обычная форма. Поэтому панель работает и без
// сценариев: без него не будет самообновления и переключателя темы,
// а всё остальное останется.
//
// Обновление — это тот же адрес, забранный заново: страница приезжает
// целиком, и меняется в ней только содержимое `main`. Так у панели
// не бывает состояния, которого нет в адресе, и после перезагрузки
// она выглядит ровно так же.
//
// Когда обновляться, говорит узел: на каждый новый снимок кластера он
// публикует обзор в канал Centrifugo, и страница, подписанная клиентом
// `centrifuge-js`, забирает себя заново по толчку — сразу после обхода,
// а не через пять секунд опроса, и только когда есть что показать.
// Опрос остаётся запасным путём: пока подписки нет — узел не извещает
// о снимках, соединение оборвалось, вход не пустил, — страница
// обновляется раз в пять секунд, как прежде.

import { Centrifuge } from 'centrifuge';

/** Как часто обновляться опросом, мс. */
const REFRESH_MS = 5000;

/** Где запоминается тема: панель открывают с разных машин. */
const THEME_KEY = 'tnt-admin-theme';

/** Канал обзора у узла. */
const CHANNEL = 'overview';

/** Обновлять ли само. */
let auto = true;

/** Идёт ли подписка на обзор: пока идёт, опрос не нужен. */
let pushed = false;

let timer = null;

/**
 * Ставит тему и запоминает её.
 *
 * @param {string} name light или dark
 */
function setTheme(name) {
    document.documentElement.setAttribute('data-bs-theme', name);

    for (const mark of document.querySelectorAll('[data-theme-mark]')) {
        mark.textContent = name === 'dark' ? '☾' : '☀';
    }

    try {
        window.localStorage.setItem(THEME_KEY, name);
    } catch (failure) {
        // Память браузера бывает закрыта настройками: тема тогда живёт
        // до перезагрузки, и это не повод падать.
    }
}

/** Забирает нынешний адрес заново и меняет содержимое страницы. */
async function refresh() {
    const taken = document.querySelector('[data-taken]');

    try {
        const response = await fetch(window.location.href, { headers: { accept: 'text/html' } });

        if (!response.ok) {
            throw new Error(`узел ответил кодом ${response.status}`);
        }

        const page = new DOMParser().parseFromString(await response.text(), 'text/html');
        const fresh = page.querySelector('[data-view]');
        const here = document.querySelector('[data-view]');

        // Поле ввода, в котором стоит курсор, не трогается: оператор
        // печатает в поиске, а панель обновляется под руками.
        if (fresh !== null && here !== null && !here.contains(document.activeElement)) {
            here.innerHTML = fresh.innerHTML;
        }

        // Шапка и метки меню приезжают с той же страницей: число находок
        // меняется чаще, чем сами находки.
        for (const name of ['[data-taken]', '.panel-menu']) {
            const from = page.querySelector(name);
            const to = document.querySelector(name);

            if (from !== null && to !== null) {
                to.innerHTML = from.innerHTML;
            }
        }
    } catch (failure) {
        if (taken !== null) {
            taken.textContent = `не обновилось: ${failure.message}`;
        }
    }
}

/**
 * Заводит или останавливает опрос.
 *
 * Опрос идёт, только когда обновляться надо, а толчка нет: подписанной
 * странице его заменяет узел, а невидимая вкладка не спрашивает узел
 * вовсе — оператор держит её открытой днями, а обход кластера стоит
 * узлу работы.
 */
function schedule() {
    clearInterval(timer);

    if (auto && !pushed && !document.hidden) {
        timer = setInterval(refresh, REFRESH_MS);
    }
}

/** Толчок узла: страница забирает себя заново, если её видно. */
function pushedRefresh() {
    if (auto && !document.hidden) {
        refresh();
    }
}

/**
 * Подписывается на обзор кластера.
 *
 * Первая подписка страницу не трогает — она только что приехала с узла.
 * Подписка, восстановленная после обрыва, забирает страницу сразу:
 * пока соединения не было, кластер мог измениться.
 *
 * @param {string} address путь точки Centrifugo у узла
 */
function subscribe(address) {
    const scheme = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const client = new Centrifuge(`${scheme}//${window.location.host}${address}`);
    const overview = client.newSubscription(CHANNEL);
    let returning = false;

    overview.on('state', (context) => {
        pushed = context.newState === 'subscribed';
        schedule();
    });

    overview.on('subscribed', () => {
        if (returning) {
            pushedRefresh();
        }

        returning = true;
    });

    overview.on('publication', pushedRefresh);
    overview.subscribe();
    client.connect();
}

let stored = null;

try {
    stored = window.localStorage.getItem(THEME_KEY);
} catch (failure) {
    stored = null;
}

setTheme(stored || 'dark');

for (const button of document.querySelectorAll('[data-theme]')) {
    button.addEventListener('click', () => {
        setTheme(document.documentElement.getAttribute('data-bs-theme') === 'dark' ? 'light' : 'dark');
    });
}

for (const button of document.querySelectorAll('[data-refresh]')) {
    button.addEventListener('click', refresh);
}

for (const button of document.querySelectorAll('[data-auto]')) {
    button.addEventListener('click', () => {
        auto = !auto;
        button.setAttribute('aria-pressed', String(auto));
        button.classList.toggle('active', auto);
        schedule();
    });
}

// Вкладка, которую снова показали, забирает страницу сразу: толчки,
// пришедшие, пока её не было видно, она пропустила.
document.addEventListener('visibilitychange', () => {
    if (!document.hidden) {
        refresh();
    }

    schedule();
});

// Адрес толчка страница несёт, только когда узел извещает о снимках:
// без него стучаться некуда, и остаётся опрос.
const live = document.body.dataset.live;

if (live) {
    subscribe(live);
}

schedule();
