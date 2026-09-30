rockspec_format = '3.0'

package = 'tnt-admin'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-admin.git',
    branch = 'main',
}

description = {
    summary = 'Панель узла и кластера: роль, которую приложение называет в конфигурации',
    detailed = [[
        Панель показывает узел и кластер вокруг: состав и состояние узлов,
        находки диагностики, подсказки оператору, узлы конфигурации
        по отбору и журнал аудита. Страницы рисует сам узел
        шаблонизатором, поэтому панель работает и без сценариев: отбор —
        это адрес, действие — обычная форма. О новом снимке кластера
        узел сообщает толчком: обзор уходит в канал Centrifugo, и браузер
        перерисовывает страницу, не опрашивая узел. Рядом с ними — HTTP API
        с JSON: код ответа настоящий, и клиент смотрит на него, а не
        разбирает текст. Стили и сценарий упакованы в модуль и раздаются
        из памяти процесса: отдельного веб-сервера для статики нет,
        и разойтись версиям панели и узла негде.

        Подключается ролью: приложение называет tnt.admin в roles рядом
        со своей ролью, а порт панели задаёт файлом config/admin.lua.
        Настройки читаются тремя слоями — умолчания пакета, файл
        приложения, раздел roles_cfg, — и незнакомое поле отвергается
        на месте. Панель встаёт на свой порт либо на сервер roles.httpd
        по имени, а снятая — закрывает свой сервер и возвращает чужому
        прежний обработчик.

        Чем панель питается, решает узел. Снимок кластера, находки,
        подсказки и отбор узлов даёт tnt-cluster-health; журнал аудита —
        tnt-audit; действия над кластером — tnt-ops и tnt-sharding
        с оценкой и воротами tnt-recovery. Эти четыре пакета панель
        берёт по имени, если они установлены рядом, и зависимостью их
        не требует: чего нет, того панель не показывает и о том отвечает
        отказом с кодом. Приложению со своим сервером и своим входом
        панель собирается и функцией «запрос — ответ» над источниками,
        которые называет оно само.

        Собрана тем же фреймворком, что и приложение под ней, и лежит
        той же раскладкой — app/, routes/, resources/views,
        bootstrap/providers.lua, — только внутри пакета, потому что едет
        роком. Тела запросов и ответов API объявлены формами tnt-data,
        и из них же вместе с маршрутами tnt-openapi собирает описание
        API: поле формы и строка описания разойтись не могут. Зависит
        от tnt-framework, tnt-kernel, tnt-router, tnt-template, tnt-di,
        tnt-config, tnt-env, tnt-error, tnt-validate, tnt-data,
        tnt-openapi, tnt-log, tnt-permissions, tnt-cluster-health,
        tnt-centrifugo, tnt-must и tnt-external. Покрытие строк и убитых
        мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-admin',
    issues_url = 'https://github.com/tnt-skein/tnt-admin/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'admin', 'dashboard', 'cluster', 'roles' },
}

dependencies = {
    'lua >= 5.1',
    -- Приложение поверх ядра: раскладка, контейнер, страницы и маршруты.
    'tnt-framework',
    -- Проверка раздела роли: настройка с опечаткой отвергается на месте.
    'tnt-must',
    -- Подмена средств узла в проверках: каталог пакета ищется загрузчиком.
    'tnt-external',
    -- Маршруты, слои, отказы и проверка тела: панель их не пишет заново.
    'tnt-router',
    'tnt-error',
    'tnt-validate',
    -- Тела запросов и ответов API формами: проверка входа, выдача и схемы.
    'tnt-data',
    -- Описание API из маршрутов, форм и слов операций.
    'tnt-openapi',
    -- Настройки панели из окружения: порт и состав источников.
    'tnt-env',
    -- Слои настроек панели — свой файл, файл приложения, раздел роли —
    -- сливаются вглубь по одним правилам.
    'tnt-config',
    -- Панель, собранная вызывающим: ядро HTTP, контейнер и страницы шаблонами.
    'tnt-kernel',
    'tnt-di',
    'tnt-template',
    -- Журнал запросов панели под её именем.
    'tnt-log',
    -- Права панели: роли, разрешения и слой права на маршрутах.
    'tnt-permissions',
    -- Диагностика: снимок кластера, находки, подсказки и отбор узлов;
    -- из её пула действия берут адреса соседей.
    'tnt-cluster-health',
    -- Толчок обзора: узел публикует обзор в канал, браузер подписан
    -- клиентом centrifuge-js и не опрашивает узел.
    'tnt-centrifugo',
    -- tnt-audit, tnt-ops, tnt-sharding и tnt-recovery панель берёт
    -- по имени, если они установлены рядом, и зависимостью не объявляет:
    -- без них она работает, только без журнала аудита и действий.
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.admin'] = 'tnt/admin.lua',
        ['tnt.admin.app.data.cluster'] = 'tnt/admin/app/data/cluster.lua',
        ['tnt.admin.app.data.refusal'] = 'tnt/admin/app/data/refusal.lua',
        ['tnt.admin.app.data.requests'] = 'tnt/admin/app/data/requests.lua',
        ['tnt.admin.app.data.results'] = 'tnt/admin/app/data/results.lua',
        ['tnt.admin.app.domain.cluster'] = 'tnt/admin/app/domain/cluster.lua',
        ['tnt.admin.app.exceptions.refusal'] = 'tnt/admin/app/exceptions/refusal.lua',
        ['tnt.admin.app.http.handlers.audit'] = 'tnt/admin/app/http/handlers/audit.lua',
        ['tnt.admin.app.http.handlers.instances'] = 'tnt/admin/app/http/handlers/instances.lua',
        ['tnt.admin.app.http.handlers.panel'] = 'tnt/admin/app/http/handlers/panel.lua',
        ['tnt.admin.app.http.middleware.authorize'] = 'tnt/admin/app/http/middleware/authorize.lua',
        ['tnt.admin.app.http.middleware.can'] = 'tnt/admin/app/http/middleware/can.lua',
        ['tnt.admin.app.http.openapi'] = 'tnt/admin/app/http/openapi.lua',
        ['tnt.admin.app.http.openapi.audit'] = 'tnt/admin/app/http/openapi/audit.lua',
        ['tnt.admin.app.http.openapi.changes'] = 'tnt/admin/app/http/openapi/changes.lua',
        ['tnt.admin.app.http.openapi.views'] = 'tnt/admin/app/http/openapi/views.lua',
        ['tnt.admin.app.http.panel'] = 'tnt/admin/app/http/panel.lua',
        ['tnt.admin.app.providers.panel'] = 'tnt/admin/app/providers/panel.lua',
        ['tnt.admin.app.services.pages'] = 'tnt/admin/app/services/pages.lua',
        ['tnt.admin.app.services.settings'] = 'tnt/admin/app/services/settings.lua',
        ['tnt.admin.app.services.sources'] = 'tnt/admin/app/services/sources.lua',
        ['tnt.admin.app.services.acting'] = 'tnt/admin/app/services/acting.lua',
        ['tnt.admin.app.services.dialing'] = 'tnt/admin/app/services/dialing.lua',
        ['tnt.admin.app.services.watch'] = 'tnt/admin/app/services/watch.lua',
        ['tnt.admin.app.services.live'] = 'tnt/admin/app/services/live.lua',
        ['tnt.admin.app.services.overview'] = 'tnt/admin/app/services/overview.lua',
        ['tnt.admin.app.support.format'] = 'tnt/admin/app/support/format.lua',
        ['tnt.admin.app.support.packages'] = 'tnt/admin/app/support/packages.lua',
        ['tnt.admin.app.support.root'] = 'tnt/admin/app/support/root.lua',
        ['tnt.admin.bootstrap.providers'] = 'tnt/admin/bootstrap/providers.lua',
        ['tnt.admin.config.admin'] = 'tnt/admin/config/admin.lua',
        ['tnt.admin.public.bundle'] = 'tnt/admin/public/bundle.lua',
        ['tnt.admin.routes.api'] = 'tnt/admin/routes/api.lua',
        ['tnt.admin.routes.web'] = 'tnt/admin/routes/web.lua',

        -- Страницы — такие же модули: рок кладёт их по имени, и второй
        -- точки в имени файла у него не бывает, поэтому
        -- `overview.thtml.lua` ложится рядом как `overview.lua`.
        -- Шаблонизатор знает оба имени и читает установленный файл тем же
        -- шаблоном.
        ['tnt.admin.resources.views.audit'] = 'tnt/admin/resources/views/audit.thtml.lua',
        ['tnt.admin.resources.views.cluster'] = 'tnt/admin/resources/views/cluster.thtml.lua',
        ['tnt.admin.resources.views.config'] = 'tnt/admin/resources/views/config.thtml.lua',
        ['tnt.admin.resources.views.issues'] = 'tnt/admin/resources/views/issues.thtml.lua',
        ['tnt.admin.resources.views.layout'] = 'tnt/admin/resources/views/layout.thtml.lua',
        ['tnt.admin.resources.views.overview'] = 'tnt/admin/resources/views/overview.thtml.lua',
        ['tnt.admin.resources.views.partials.action-form'] = 'tnt/admin/resources/views/partials/action-form.thtml.lua',
        ['tnt.admin.resources.views.partials.dot'] = 'tnt/admin/resources/views/partials/dot.thtml.lua',
        ['tnt.admin.resources.views.partials.empty'] = 'tnt/admin/resources/views/partials/empty.thtml.lua',
        ['tnt.admin.resources.views.partials.heading'] = 'tnt/admin/resources/views/partials/heading.thtml.lua',
        ['tnt.admin.resources.views.partials.issue'] = 'tnt/admin/resources/views/partials/issue.thtml.lua',
        ['tnt.admin.resources.views.partials.memory'] = 'tnt/admin/resources/views/partials/memory.thtml.lua',
        ['tnt.admin.resources.views.partials.replicaset-server'] = 'tnt/admin/resources/views/partials/replicaset-server.thtml.lua',
        ['tnt.admin.resources.views.partials.tile'] = 'tnt/admin/resources/views/partials/tile.thtml.lua',
    },
}
