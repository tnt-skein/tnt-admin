--- Общие средства проверок панели.
---
--- Исходники панели читаются с диска, а не через `require`: у Tarantool
--- свой загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему.
---
--- Соседи — ядро, фреймворк, права, формы с описанием API, Centrifugo
--- и всё, что они берут сами, — тоже грузятся файлами, но из `.rocks`,
--- куда их ставит `make deps`, и заново на каждую проверку. Каталог
--- отказов, реестр форм, подмены средств ядра и журнала живут в их
--- модулях, и оставленные соседней проверкой они сделали бы порядок
--- проверок частью их смысла. Проверяется эта панель, а не они: `.rocks`
--- в покрытие не входит.
---
--- Роль грузится последней и отдельно: при загрузке она собирает
--- раскладку от каталога пакета, а каталог ей надо показать исходниками
--- репозитория, а не установленной копией.
---
--- Оснастка в `test/testing/` — загрузчик исходников, файлы, ловушка
--- журнала и узлы luatest — грузится так же и один раз на процесс: второй
--- экземпляр загрузчика не знал бы, что вытеснил первый, и не вернул бы
--- вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- там, где панель живёт рядом со своими зависимостями. Соседей, которых
--- проверки поднимают целиком, — диагностику кластера и узел с журналом
--- аудита — они тоже берут здесь.

local fio = require('fio')
local http_server = require('http.server')
local json = require('json')

--- Модули оснастки в порядке зависимостей: узел берёт файлы и загрузчик,
--- ловушка журнала — загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

local sources = package.loaded['tnt.testing.sources']
local files = package.loaded['tnt.testing.files']
local node = package.loaded['tnt.testing.node']

local helper = {}

--- Оснастка проверок под теми именами, что зовут проверки.
---
--- Только то, чем проверки пользуются: модуль той же загрузки, загрузка
--- и выгрузка исходников и ловушка журнала.
helper.testing = {
    module = sources.module,
    load_sources = sources.load,
    unload_sources = sources.unload,
    capture_log = package.loaded['tnt.testing.journal'].capture,
    read_file = files.read,
}

--- Каталог раскладки панели в репозитории.
helper.ROOT = 'tnt/admin'

--- Собранное описание API панели: с ним проверки сличают документ,
--- который собирает `tnt.admin.app.http.openapi`.
helper.API_SPEC = 'docs/api/panel.yaml'

--- Модули форм панели: имя модуля → путь исходника. Аннотации форм
--- проверки сверяют с объявлениями по тексту модуля.
helper.FORMS = {
    ['tnt.admin.app.data.requests'] = helper.ROOT .. '/app/data/requests.lua',
    ['tnt.admin.app.data.cluster'] = helper.ROOT .. '/app/data/cluster.lua',
    ['tnt.admin.app.data.results'] = helper.ROOT .. '/app/data/results.lua',
    ['tnt.admin.app.data.refusal'] = helper.ROOT .. '/app/data/refusal.lua',
}

--- Список модулей по именам: путь складывается из имени от приставки.
---@param prefix string Каталог с модулями: пусто — корень репозитория
---@param names string[] Имена модулей в порядке зависимостей
---@return TntTestingSource[]
local function listed(prefix, names)
    local list = {}

    for _, name in ipairs(names) do
        table.insert(list, { name = name, path = prefix .. name:gsub('%.', '/') .. '.lua' })
    end

    return list
end

--- Где `make deps` кладёт модули соседей.
local ROCKS = '.rocks/share/tarantool/'

--- Соседи в порядке зависимостей — из `.rocks`.
---
--- Первым идёт то, что берут, последним — то, что берёт: загруженный
--- позже модуль достался бы только тем, кто грузился после него. Ядро
--- с фреймворком — посередине, права, формы, описание API и Centrifugo
--- с WebSocket — за ними. Повторов нет: проверяльщика берут и ядро,
--- и куки, а загруженный второй раз модуль достался бы только тем, кто
--- грузился после него.
local NEIGHBOURS = listed(ROCKS, {
    'tnt.external',
    'tnt.log',
    'tnt.validate.text',
    'tnt.validate.rule',
    'tnt.validate.coerce',
    'tnt.validate.regex',
    'tnt.validate.rules',
    'tnt.validate.formats',
    'tnt.validate.check',
    'tnt.validate.settings',
    'tnt.validate',
    'tnt.must.fail',
    'tnt.must.types',
    'tnt.must.range',
    'tnt.must.text',
    'tnt.must.choice',
    'tnt.must.cdata',
    'tnt.must.spec',
    'tnt.must',
    'tnt.id.octets',
    'tnt.id.quote',
    'tnt.id.crockford',
    'tnt.error.secret',
    'tnt.error.failure',
    'tnt.error.hook',
    'tnt.error.incident',
    'tnt.error.catalog',
    'tnt.error.render',
    'tnt.error.accept',
    'tnt.error.options',
    'tnt.error.page',
    'tnt.error.translation',
    'tnt.error.web',
    'tnt.error',
    'tnt.validate.file',
    'tnt.hash.algorithm',
    'tnt.hash.encoding',
    'tnt.hash.compare',
    'tnt.hash.compute',
    'tnt.hash.stream',
    'tnt.hash.password',
    'tnt.hash',
    'tnt.fs.failure',
    'tnt.fs.system',
    'tnt.fs.writer',
    'tnt.fs.reader',
    'tnt.fs.file',
    'tnt.fs.tree',
    'tnt.fs.temp',
    'tnt.fs',
    'tnt.context.key',
    'tnt.context',
    'tnt.log.plain',
    'tnt.metrics.series.labels',
    'tnt.metrics.series.collector',
    'tnt.metrics.series',
    'tnt.router.neighbour',
    'tnt.router.options',
    'tnt.router.blame',
    'tnt.router.path',
    'tnt.router.constraints',
    'tnt.router.tree',
    'tnt.router.multipart',
    'tnt.router.upload',
    'tnt.router.form',
    'tnt.router.request',
    'tnt.router.response',
    'tnt.router.takeover',
    'tnt.router.errors',
    'tnt.router.signed',
    'tnt.router.address',
    'tnt.router.files.caching',
    'tnt.router.files.store',
    'tnt.router.files',
    'tnt.router.etag',
    'tnt.router.view',
    'tnt.router.pipeline',
    'tnt.router.declare',
    'tnt.router.series',
    'tnt.router.answer',
    'tnt.router',
    'tnt.id.entropy',
    'tnt.id.sequence',
    'tnt.id.uuid7',
    'tnt.id.ulid',
    'tnt.id',
    'tnt.clock',
    'tnt.middleware.fall',
    'tnt.middleware.blame',
    'tnt.middleware.chain',
    'tnt.middleware.filter',
    'tnt.middleware.layer.common',
    'tnt.middleware.layer.cors',
    'tnt.middleware.layer.log',
    'tnt.middleware.layer.timing',
    'tnt.middleware.layer.rescue',
    'tnt.middleware.layer.request_id',
    'tnt.middleware.layer.request_id_header',
    'tnt.middleware.registry',
    'tnt.middleware',
    'tnt.env.cast',
    'tnt.env.example',
    'tnt.env.parse',
    'tnt.env.secret',
    'tnt.env',
    'tnt.model.world',
    'tnt.model.failure',
    'tnt.model.stamp',
    'tnt.model.hook',
    'tnt.model.shape',
    'tnt.model.order',
    'tnt.model.check',
    'tnt.model.scope',
    'tnt.model.tuple',
    'tnt.model.topology',
    'tnt.model.migration',
    'tnt.model.query',
    'tnt.model.record',
    'tnt.model.factory',
    'tnt.model.entity',
    'tnt.model.gateway.local',
    'tnt.model.gateway.sharded',
    'tnt.model.gateway.remote',
    'tnt.model.gateway.forward',
    'tnt.model.serve',
    'tnt.model.binding',
    'tnt.model',
    'tnt.collection.value',
    'tnt.collection.guard',
    'tnt.collection.kind',
    'tnt.collection.path',
    'tnt.collection.order',
    'tnt.collection.sort',
    'tnt.collection.group',
    'tnt.collection.list',
    'tnt.collection.aggregate',
    'tnt.collection.merge',
    'tnt.collection.dict',
    'tnt.collection.chain',
    'tnt.collection',
    'tnt.storage.codes',
    'tnt.storage.failure',
    'tnt.storage.exact',
    'tnt.storage.value',
    'tnt.storage.within',
    'tnt.storage.link',
    'tnt.storage.statement',
    'tnt.storage.transaction',
    'tnt.storage.driver',
    'tnt.storage',
    'tnt.sql.kinds',
    'tnt.sql.dialect',
    'tnt.sql.names',
    'tnt.sql.context',
    'tnt.sql.raw',
    'tnt.sql.where',
    'tnt.sql.select',
    'tnt.sql.insert',
    'tnt.sql.change',
    'tnt.sql.table',
    'tnt.sql',
    'tnt.orm.world',
    'tnt.orm.columns',
    'tnt.orm.ddl',
    'tnt.orm.query',
    'tnt.orm.refusal',
    'tnt.orm.gateway',
    'tnt.orm',
    'tnt.trace.w3c',
    'tnt.trace.queue',
    'tnt.trace.span',
    'tnt.trace.hook',
    'tnt.trace.layer',
    'tnt.trace.message',
    'tnt.trace',
    'tnt.retry.attempt',
    'tnt.retry.backoff',
    'tnt.retry.classify',
    'tnt.retry.rule',
    'tnt.retry.budget',
    'tnt.retry.breaker',
    'tnt.retry.options',
    'tnt.retry.runner',
    'tnt.retry',
    'tnt.http.url',
    'tnt.http.body',
    'tnt.http.response',
    'tnt.http.failure',
    'tnt.http.policy',
    'tnt.http.settings',
    'tnt.http.transport',
    'tnt.http.stream',
    'tnt.http.hook',
    'tnt.http',
    'tnt.loop',
    'tnt.compress.system',
    'tnt.compress.zlib',
    'tnt.compress.failure',
    'tnt.compress.stream',
    'tnt.compress.deflater',
    'tnt.compress.inflater',
    'tnt.compress.layer',
    'tnt.compress',
    'tnt.trace.otlp.encode',
    'tnt.trace.otlp.reply',
    'tnt.trace.otlp.settings',
    'tnt.trace.otlp',
    'tnt.config.failure',
    'tnt.config.value',
    'tnt.config.reader',
    'tnt.config.writer',
    'tnt.config.settings',
    'tnt.config',
    'tnt.di',
    'tnt.schema',
    'tnt.kernel.world',
    'tnt.kernel.list',
    'tnt.kernel.http',
    'tnt.kernel.models',
    'tnt.kernel.tracing',
    'tnt.kernel.notifier',
    'tnt.kernel.spec',
    'tnt.kernel.signing',
    'tnt.kernel.settings',
    'tnt.kernel.journal',
    'tnt.kernel.schema',
    'tnt.kernel.iproto',
    'tnt.kernel',
    'tnt.cookie.octet',
    'tnt.cookie.date',
    'tnt.cookie.parse',
    'tnt.cookie.build',
    'tnt.cookie.sign',
    'tnt.cookie.suffix',
    'tnt.cookie.jar',
    'tnt.cookie',
    'tnt.downtime',
    'tnt.template.escape',
    'tnt.template.csrf',
    'tnt.template.sandbox',
    'tnt.template.sections',
    'tnt.template.directives',
    'tnt.template.translator',
    'tnt.template.source',
    'tnt.template.fragment',
    'tnt.template.stream',
    'tnt.template.engine',
    'tnt.template.warm',
    'tnt.template',
    'tnt.cache.series',
    'tnt.cache.record',
    'tnt.cache.lock',
    'tnt.cache.tagged',
    'tnt.cache.store',
    'tnt.cache.memory',
    'tnt.cache.redis',
    'tnt.cache.space',
    'tnt.cache',
    'tnt.str.chars',
    'tnt.str.guard',
    'tnt.str.json',
    'tnt.str.case',
    'tnt.str.edit',
    'tnt.str.cut',
    'tnt.str.checks',
    'tnt.str.russian',
    'tnt.str.convert',
    'tnt.str.encoding',
    'tnt.str.regex',
    'tnt.str.fluent',
    'tnt.str',
    'tnt.i18n.locale',
    'tnt.i18n.plural',
    'tnt.i18n.messages',
    'tnt.i18n.layer',
    'tnt.i18n.translator',
    'tnt.i18n',
    'tnt.throttle.limit',
    'tnt.throttle.memory',
    'tnt.throttle.redis',
    'tnt.throttle.layer',
    'tnt.throttle.limiter',
    'tnt.throttle',
    'tnt.pool.settings',
    'tnt.pool.opening',
    'tnt.pool.waiters',
    'tnt.pool',
    'tnt.tls.library',
    'tnt.tls.outcome',
    'tnt.tls.options',
    'tnt.tls.buffer',
    'tnt.tls.openssl',
    'tnt.tls.link',
    'tnt.tls',
    'tnt.redis.resp',
    'tnt.redis.link',
    'tnt.redis.settings',
    'tnt.redis',
    'tnt.postgres.settings',
    'tnt.postgres.rock',
    'tnt.postgres',
    'tnt.mysql.settings',
    'tnt.mysql.rock',
    'tnt.mysql',
    'tnt.mail.encode',
    'tnt.mail.message',
    'tnt.mail.parse',
    'tnt.mail.text',
    'tnt.mail.refusal',
    'tnt.mail.series',
    'tnt.mail.preview',
    'tnt.mail.letters',
    'tnt.mail.transport',
    'tnt.mail.smtp',
    'tnt.mail.pop3',
    'tnt.mail.imap',
    'tnt.mail',
    'tnt.date.explain',
    'tnt.date.moment',
    'tnt.date.arith',
    'tnt.date.http',
    'tnt.date.human',
    'tnt.date.iso',
    'tnt.date.mail',
    'tnt.date',
    'tnt.s3.xml',
    'tnt.s3.sign',
    'tnt.s3.reply',
    'tnt.s3.settings',
    'tnt.s3.call',
    'tnt.s3.download',
    'tnt.s3.upload',
    'tnt.s3.transfer',
    'tnt.s3',
    'tnt.files.failure',
    'tnt.files.settings',
    'tnt.files.reader',
    'tnt.files.writer',
    'tnt.files.driver.local',
    'tnt.files.driver.s3',
    'tnt.files.disk',
    'tnt.files',
    'tnt.debug.scalar',
    'tnt.debug.describe',
    'tnt.debug.measure',
    'tnt.debug.fibers',
    'tnt.debug',
    'tnt.process.failure',
    'tnt.process.system',
    'tnt.process.locate',
    'tnt.process.child',
    'tnt.process.run',
    'tnt.process',
    'tnt.console.system',
    'tnt.console.phrases',
    'tnt.console.declaration',
    'tnt.console.parser',
    'tnt.console.output',
    'tnt.console.app',
    'tnt.console.remote',
    'tnt.console',
    'tnt.session.state',
    'tnt.session.cache',
    'tnt.session.cookie',
    'tnt.session.refusal',
    'tnt.session.layer',
    'tnt.session.csrf',
    'tnt.session.manager',
    'tnt.session',
    'tnt.framework.asset',
    'tnt.framework.canonical',
    'tnt.framework.dump',
    'tnt.framework.files',
    'tnt.framework.services',
    'tnt.framework.session',
    'tnt.framework.cors',
    'tnt.framework.spec',
    'tnt.framework.config',
    'tnt.framework.downtime',
    'tnt.framework.lang',
    'tnt.framework.models',
    'tnt.framework.layout',
    'tnt.framework.migrations',
    'tnt.framework.seeders',
    'tnt.framework.database',
    'tnt.framework.commands',
    'tnt.framework.pages',
    'tnt.framework.providers',
    'tnt.framework.offline',
    'tnt.framework.bootstrap',
    'tnt.framework',
    'tnt.permissions.ability',
    'tnt.permissions.verdict',
    'tnt.permissions.roles',
    'tnt.permissions.refusal',
    'tnt.permissions.decide',
    'tnt.permissions.layer',
    'tnt.permissions.gate',
    'tnt.permissions',
    'tnt.data.field',
    'tnt.data.rules',
    'tnt.data.output',
    'tnt.data.annotation',
    'tnt.data.openapi',
    'tnt.data.shape',
    'tnt.data',
    'tnt.openapi.paths',
    'tnt.openapi.operation',
    'tnt.openapi.declare',
    'tnt.openapi.document',
    'tnt.openapi.served',
    'tnt.openapi',
    'tnt.websocket.codes',
    'tnt.websocket.failure',
    'tnt.websocket.frame',
    'tnt.websocket.wire',
    'tnt.websocket.handshake',
    'tnt.websocket.deflate',
    'tnt.websocket.settings',
    'tnt.websocket.connection',
    'tnt.websocket.server',
    'tnt.websocket.client',
    'tnt.websocket',
    'tnt.centrifugo.codes',
    'tnt.centrifugo.protocol',
    'tnt.centrifugo.reign',
    'tnt.centrifugo.schema',
    'tnt.centrifugo.keeper',
    'tnt.centrifugo.listener',
    'tnt.centrifugo.link',
    'tnt.centrifugo.bus',
    'tnt.centrifugo.settings',
    'tnt.centrifugo.registry',
    'tnt.centrifugo.client',
    'tnt.centrifugo.recovery',
    'tnt.centrifugo.commands',
    'tnt.centrifugo.session',
    'tnt.centrifugo.hub',
    'tnt.centrifugo',
})

--- Части панели в порядке зависимостей — всё, кроме самой роли.
local PARTS = listed('', {
    'tnt.admin.app.support.packages',
    'tnt.admin.app.support.format',
    'tnt.admin.app.domain.cluster',
    'tnt.admin.app.services.pages',
    'tnt.admin.app.support.root',
    'tnt.admin.app.exceptions.refusal',
    'tnt.admin.app.data.requests',
    'tnt.admin.app.data.cluster',
    'tnt.admin.app.data.results',
    'tnt.admin.app.data.refusal',
    'tnt.admin.app.services.overview',
    'tnt.admin.app.http.middleware.authorize',
    'tnt.admin.app.http.middleware.can',
    'tnt.admin.app.services.live',
    'tnt.admin.app.http.handlers.panel',
    'tnt.admin.app.http.handlers.audit',
    'tnt.admin.app.http.handlers.instances',
    'tnt.admin.app.http.panel',
    'tnt.admin.app.http.openapi.views',
    'tnt.admin.app.http.openapi.changes',
    'tnt.admin.app.http.openapi.audit',
    'tnt.admin.app.http.openapi',
    'tnt.admin.public.bundle',
    'tnt.admin.app.services.sources',
    'tnt.admin.app.services.dialing',
    'tnt.admin.app.services.acting',
    'tnt.admin.app.services.watch',
    'tnt.admin.app.services.settings',
    'tnt.admin.config.admin',
    'tnt.admin.app.providers.panel',
    'tnt.admin.bootstrap.providers',
    'tnt.admin.routes.api',
    'tnt.admin.routes.web',
})

--- Роль: грузится после того, как частям показан каталог пакета.
local ROLE = listed('', { 'tnt.admin' })

--- Соседи и части панели: всё, что грузится до роли.
local BASE = sources.merge(NEIGHBOURS, PARTS)

--- Модули, которые проверки панели грузят исходниками.
helper.MODULES = sources.merge(BASE, ROLE)

--- Модель кластера одна, без ядра и фреймворка: модуль чистый, ничего
--- не берёт, и проверке его представления сборка остального ни к чему.
helper.MODEL = listed('', { 'tnt.admin.app.domain.cluster' })

--- Диагностика кластера вместе со всем, что она берёт, — из `.rocks`.
---
--- Отбор узлов проверяется и на настоящей диагностике: имена полей отбора,
--- вид узла и слова отказа — стык двух пакетов, и двойником одной
--- стороны его не проверить. Грузится файлами, как и остальные соседи:
--- проверка подменяет диагностике конфигурацию кластера, и подмена
--- уходит вместе с выгрузкой.
helper.CLUSTER = listed(ROCKS, {
    'tnt.external',
    'tnt.clock',
    'tnt.must.fail',
    'tnt.must.types',
    'tnt.must.range',
    'tnt.must.text',
    'tnt.must.choice',
    'tnt.must.cdata',
    'tnt.must.spec',
    'tnt.must',
    'tnt.context.key',
    'tnt.context',
    'tnt.log.plain',
    'tnt.log',
    'tnt.async.task',
    'tnt.async.group',
    'tnt.async',
    'tnt.cluster.fanout',
    'tnt.fingerprint',
    'tnt.collection.value',
    'tnt.collection.guard',
    'tnt.collection.kind',
    'tnt.collection.path',
    'tnt.collection.order',
    'tnt.collection.sort',
    'tnt.collection.group',
    'tnt.collection.list',
    'tnt.collection.aggregate',
    'tnt.collection.merge',
    'tnt.collection.dict',
    'tnt.collection.chain',
    'tnt.collection',
    'tnt.cluster.probe',
    'tnt.labels',
    'tnt.cluster.pool',
    'tnt.cluster.state',
    'tnt.cluster.issues',
    'tnt.cluster.rules',
    'tnt.id.octets',
    'tnt.id.quote',
    'tnt.id.crockford',
    'tnt.id.entropy',
    'tnt.id.sequence',
    'tnt.id.uuid7',
    'tnt.id.ulid',
    'tnt.id',
    'tnt.loop',
    'tnt.cluster.poller',
    'tnt.cluster',
})

--- Соседи и части панели без роли — путями от корня.
---
--- Для узла, который поднимает проверка: он живёт в своём каталоге,
--- и относительный путь привёл бы его не туда. Роли в списке нет: её
--- загрузка собирает раскладку, а на узле, поднятом без кластерной
--- конфигурации, собирать нечего.
helper.ON_NODE = sources.absolute(BASE)

--- Минимальная арена узла журнала: журналу аудита в проверках хватает.
local JOURNAL_MEMORY = 32 * 1024 * 1024

--- Списки, которые узел журнала собирает заново перед каждой проверкой, —
--- из `.rocks` и с путями от корня: узел живёт в своём каталоге.
---
--- Раннер миграций — отдельно: журнал регистрирует в нём свои шаги,
--- и проверке нужен свой, чистый. То, что журнал берёт сам, — часы,
--- журнал узла, цикл, сжатие, — узел находит обычным `require`.
local JOURNAL_LISTS = {
    schema = sources.absolute(listed(ROCKS, { 'tnt.schema' })),
    facade = sources.absolute(listed(ROCKS, {
        'tnt.audit.chain',
        'tnt.audit.space',
        'tnt.audit.log',
        'tnt.audit.verify',
        'tnt.audit.retention',
        'tnt.audit.export.envelope',
        'tnt.audit.export.cursor',
        'tnt.audit.export.sink.file',
        'tnt.audit.export',
        'tnt.audit.stream',
        'tnt.audit',
    })),
}

--- Поднимает узел для журнала: узел оснастки, под строгим режимом глобалов.
---
--- Узел берёт загрузчик исходников оснастки: им он собирает раннер,
--- журнал и панель заново перед каждой проверкой — функцию
--- в `server:exec` не передать, туда уходит только её тело.
---@return table server
local function start_journal()
    return node.start({
        modules = { { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' } },
        box_cfg = { memtx_memory = JOURNAL_MEMORY },
    })
end

--- Разворачивает чистый журнал на узле: сносит спейсы, собирает журнал
--- заново и прогоняет миграцию. Журнал ложится в `_G.audit`.
---@param server table
local function prepare_journal(server)
    server:exec(function(lists)
        for _, name in ipairs({ 'app_audit', 'app_audit_export', 'app_schema_meta' }) do
            if box.space[name] ~= nil then
                box.space[name]:drop()
            end
        end

        local loader = require('tnt.testing.sources')
        local schema = loader.load(lists.schema, 'tnt.schema')
        local audit = loader.load(lists.facade, 'tnt.audit')

        audit.register_migrations(schema)
        schema.upgrade()

        rawset(_G, 'audit', audit)
    end, { JOURNAL_LISTS })
end

--- Наполняет журнал записями с настоящей цепочкой хешей, минуя писателя.
---
--- Через `record` тысячи записей клались бы вдвое дольше, а отметку
--- времени каждой всё равно пришлось бы двигать часами. Цепочка при этом
--- настоящая: хеши считает тот же модуль, что и писатель.
---
--- Зоны идут подряд по номеру, а журнал перед вызовом пуст: номера
--- начинаются с единицы и растут сквозь все зоны, отметка времени внутри
--- зоны растёт от `at` на единицу за запись.
---@param server table
---@param zones { count: integer, at: integer }[] Сколько записей класть и от какой отметки времени (мкс)
local function fill_journal(server, zones)
    server:exec(function(plan)
        local fiber = require('fiber')

        --- Сколько записей ложится одной транзакцией: запись в WAL
        --- на каждую строку растянула бы наполнение в разы, а партия много
        --- крупнее упёрлась бы в срез файбера — внутри транзакции уступки нет.
        local PORTION = 10000

        local chain = _G.audit.chain
        ---@type any
        local space = box.space[_G.audit.space.name()]

        local id = 0
        ---@type string|nil
        local previous

        box.begin()

        for _, zone in ipairs(plan) do
            for index = 1, zone.count do
                id = id + 1

                local row = { id = id, ts = zone.at + index, action = 'действие' }
                local hash = chain.row_hash(previous, row)

                space:insert({
                    id,
                    row.ts,
                    box.NULL,
                    row.action,
                    box.NULL,
                    box.NULL,
                    box.NULL,
                    previous,
                    hash,
                    false,
                })

                previous = hash

                -- Уступка между партиями: узел отвечает и во время
                -- наполнения, а транзакцию уступка внутри неё оборвала бы.
                if id % PORTION == 0 then
                    box.commit()
                    fiber.yield()
                    box.begin()
                end
            end
        end

        box.commit()
    end, { zones })
end

--- Узел с настоящим журналом аудита: поднять, остановить, очистить
--- журнал и наполнить его записями.
---
--- Журнал за проводом проверяется на живом узле — `box` настроен только
--- там, — и журнал на нём тот, что ставит `make deps`: схема и выгрузка
--- у него свои, и переписанные сюда разошлись бы с ним на первой же правке.
helper.journal = {
    start = start_journal,
    stop = node.stop,
    prepare = prepare_journal,
    fill = fill_journal,
}

--- Процессы — фасад `tnt-process`: живая сверка толчка зовёт им Node
--- с официальным клиентом `centrifuge-js`.
---
--- Установленный, обычным `require`: он нужен одной живой сверке, и его
--- код здесь не проверяется.
---@return table
function helper.process()
    return require('tnt.process')
end

---@class TntKernelFakeServer
---@field options { handler: function } Обработчик всех запросов, как у рока
---@field original function Обработчик, с которым сервер был собран
---@field idle_timeout number|nil Срок простоя, который поставило ядро

--- Двойник сервера http.server: обработчик всех запросов в `options.handler`
--- и больше ничего.
---@return TntKernelFakeServer
function helper.fake_server()
    local function refusing()
        return { status = 404, body = 'сервер отвечает сам' }
    end

    local server = { options = { handler = refusing }, original = refusing, stopped = false, started = false }

    --- Подъём сервера: у своего порта его зовёт ядро, подняв сервер роком.
    function server:start()
        self.started = true
    end

    --- Закрытие сервера: его зовёт ядро у своего порта, а у чужого —
    --- не должно звать вовсе.
    function server:stop()
        self.stopped = true
    end

    return server
end

--- Двойник встроенного журнала: `cfg` — и вызов, и таблица настроек,
--- как у ядра. Что передали, копится в `applied`.
---@return table
local function fake_journal()
    local journal = { applied = {} }

    journal.cfg = setmetatable({ level = 'info', format = 'json', modules = { ['tnt.pool'] = 'warn' } }, {
        __call = function(current, opts)
            table.insert(journal.applied, opts)

            for key, value in pairs(opts) do
                current[key] = value
            end
        end,
    })

    return journal
end

---@class TntKernelFakeNotifier
---@field asked string[] Что ядро просило у уведомителя, по порядку
---@field publish_health_checks fun()
---@field withdraw_health_checks fun()

--- Двойник уведомителя: ровно то, чем пользуется ядро. Что просили,
--- копится в `asked` — `publish` и `withdraw`.
---@return TntKernelFakeNotifier
local function fake_notifier()
    local notifier = { asked = {} }

    function notifier.publish_health_checks()
        table.insert(notifier.asked, 'publish')
    end

    function notifier.withdraw_health_checks()
        table.insert(notifier.asked, 'withdraw')
    end

    return notifier
end

---@class TntKernelWorld
---@field roles string[] Роли инстанса
---@field server any Что `roles.httpd` отдаёт вместо сервера; пусто — сервера нет
---@field requested string|nil Имя сервера, которое у него просили
---@field hierarchy table Место узла
---@field is_router boolean
---@field is_storage boolean
---@field labels table|nil
---@field journal table|nil Двойник встроенного журнала: `cfg` зовётся и читается, как у ядра; пусто — настоящий
---@field bucket_count integer Число бакетов — моделям на хранилище
---@field instances table<string, table> Узлы кластера по имени — моделям для `remote`
---@field uris table<string, table> Адреса узлов под учёткой sharding — моделям для `remote`
---@field box table|nil Двойник `box` для моделей на узле с данными; пусто — настоящий
---@field net_box table|nil Двойник `net.box` для шлюза `remote`; пусто — настоящий
---@field notifier TntKernelFakeNotifier Двойник уведомителя: настоящий в проверках не трогается
---@field served { host: string, port: number }|nil Адрес, на котором роль подняла свой сервер

--- Мир вокруг роли: конфигурация ядра и роль сервера — двойниками. Тот
--- же, каким проверяется само ядро: роль панели встаёт на ядро так же,
--- как роль приложения.
---
--- Поля меняются проверкой на ходу: внешние зависимости читают их при
--- каждом обращении, и «сервер пропал при перечитывании» — это одно
--- присваивание.
---@param overrides table|nil
---@return TntKernelWorld
function helper.world(overrides)
    local world = {
        roles = { 'roles.httpd', 'test.app' },
        server = helper.fake_server(),
        requested = nil,
        hierarchy = { group = 'routers', replicaset = 'router-001', instance = 'router-001-a' },
        is_router = true,
        is_storage = false,
        labels = { zone = 'a' },
        journal = fake_journal(),
        bucket_count = 100,
        instances = {},
        uris = {},
        notifier = fake_notifier(),
    }

    for key, value in pairs(overrides or {}) do
        world[key] = value
    end

    return world
end

--- Роли шардирования узла, как их отдаёт `config:get('sharding.roles')`.
---
--- Считаются от того же мира, что и `is_router`/`is_storage` ядра:
--- модели спрашивают у конфигурации роли, ядро — признаки, и в проверке
--- они обязаны говорить одно.
---@param world TntKernelWorld
---@return string[]
local function sharding_roles_of(world)
    local roles = {}

    if world.is_router then
        table.insert(roles, 'router')
    end

    if world.is_storage then
        table.insert(roles, 'storage')
    end

    return roles
end

--- Ставит внешние зависимости моделей на двойники того же мира.
---
--- Конфигурация у моделей своя, не ядра: они читают роли шардирования,
--- число бакетов и адреса соседей — того, что ядру не нужно. `box`
--- и `net.box` читаются из мира при каждом обращении: проверка ставит
--- двойника после загрузки, а без него идут настоящие.
---@param world TntKernelWorld
local function arm_models(world)
    sources.module('tnt.model')._set_source({
        config = function()
            return {
                get = function(_, path)
                    if path == 'sharding.roles' then
                        return sharding_roles_of(world)
                    end

                    assert(
                        path == 'sharding.bucket_count',
                        'модели спрашивают у конфигурации только шардирование'
                    )

                    return world.bucket_count
                end,
                info = function()
                    return { hierarchy = world.hierarchy }
                end,
                instances = function()
                    return world.instances
                end,
                instance_uri = function(_, _, opts)
                    return world.uris[opts.instance]
                end,
            }
        end,

        box = function()
            return world.box or rawget(_G, 'box')
        end,

        net_box = function()
            return world.net_box or require('net.box')
        end,
    })
end

--- Ставит внешние зависимости ядра на двойники мира.
---@param world TntKernelWorld
---@param kernel any Модуль ядра, загруженный файлом
local function arm(world, kernel)
    -- Журнал подменяется, только если мир его завёл: без двойника
    -- проверка идёт в настоящий встроенный журнал процесса.
    local replacement = {
        config = function()
            return {
                info = function()
                    return { hierarchy = world.hierarchy }
                end,
                is_router = function()
                    return world.is_router
                end,
                is_storage = function()
                    return world.is_storage
                end,
                get = function(_, key)
                    assert(
                        key == 'labels',
                        'ядро спрашивает у конфигурации только labels'
                    )

                    return world.labels
                end,
            }
        end,

        httpd = function()
            return {
                -- Имя сервера ядро передаёт, и двойник обязан его принимать:
                -- средство, отличающееся от настоящего числом аргументов,
                -- в проверке ведёт себя не так, как в кластере.
                get_server = function(name)
                    world.requested = name

                    return world.server
                end,
            }
        end,

        -- Рок сервера: роль со своим портом поднимает его сама, и проверке
        -- надо видеть адрес, а не занимать настоящий порт.
        http_server = function()
            return {
                new = function(host, port)
                    world.served = { host = host, port = port }

                    return world.server
                end,
            }
        end,

        roles = function()
            return world.roles
        end,

        -- Уведомитель один на процесс, и его реестр проверок — тоже:
        -- настоящий, тронутый проверкой, заводил бы проверки в реестре
        -- процесса проверок.
        notifier = function()
            return world.notifier
        end,
    }

    if world.journal ~= nil then
        replacement.journal = function()
            return world.journal
        end
    end

    kernel._set_source(replacement)
    arm_models(world)
end

---@class TntKernelIncoming
---@field method string|nil Способ; по умолчанию GET
---@field path string Путь, как его прислал клиент, до раскодирования
---@field query string|nil Строка запроса
---@field body any Тело; таблица уходит JSON, строка — как есть
---@field headers table<string, string>|nil Заголовки, имена в нижнем регистре

--- Собирает запрос в том виде, в каком его отдаёт http.server.
---
--- Тело отдаётся так, как его отдаёт сервер: `Content-Length` по длине,
--- чтение не больше заявленного; что спросили, запоминается в `asked`.
---@param opts TntKernelIncoming
---@return table
function helper.incoming(opts)
    local headers = opts.headers or {}
    local text = opts.body

    if type(text) == 'table' then
        text = json.encode(text)
    end

    if text ~= nil then
        headers['content-length'] = tostring(#text)
    end

    local asked = {}

    return {
        method = opts.method or 'GET',
        path_raw = opts.path,
        path = opts.path,
        query = opts.query or '',
        headers = headers,
        asked = asked,
        read = function(_, size, timeout)
            table.insert(asked, { size = size, timeout = timeout })

            return text:sub(1, size)
        end,
    }
end

--- Загружает соседей и части панели и показывает им каталог пакета
--- в репозитории.
---
--- Каталог — исходниками, а не поиском загрузчика: `package.search`
--- нашёл бы установленную копию, и проверка шла бы по вчерашним
--- страницам и маршрутам.
---
--- Соседей, которых панель берёт по имени, — диагностику кластера —
--- проверка называет вторым аргументом, и они грузятся тем же списком,
--- первыми: общие модули у них с панелью одни, и загруженные дважды
--- они разошлись бы подменами. Выгружает их проверка сама.
---@param name string Какую часть вернуть, например tnt.admin.app.services.settings
---@param neighbours TntTestingSource[]|nil Соседи панели, которых она берёт по имени
---@return any
function helper.load(name, neighbours)
    local loaded = sources.load(sources.merge(neighbours or {}, BASE), name)

    sources.module('tnt.admin.app.support.root')._set_source({
        anchor = function()
            return helper.ROOT .. '.lua'
        end,
    })

    return loaded
end

--- Загружает панель целиком: части, роль поверх них и внешние зависимости
--- ядра на двойники мира.
---
--- Порядок обязателен: роль при загрузке зовёт фреймворк и собирает
--- раскладку, а части, загруженные после неё, достались бы ей прежними.
---@param world TntKernelWorld
---@return any admin Роль панели
function helper.role(world)
    helper.load('tnt.admin.app.support.root')

    local admin = sources.load(ROLE, 'tnt.admin')

    arm(world, sources.module('tnt.kernel'))

    return admin
end

---@class TntAdminPanel Панель, собранная для проверок
---@field ask fun(method: string, path: string, body: string|nil, extra: table|nil): table Запрос к панели
---@field serve fun(request: table): table Запрос как есть, собранный проверкой
---@field routes fun(): string[] Пути именованных маршрутов

--- Собирает панель на двойнике сервера с назваными источниками.
---
--- Границу собирает ядро (`tnt.kernel.http`) — тем же вызовом, каким
--- её собирает роль: каталог отказов с видом панели, слои входа,
--- страж и движок страниц из раскладки пакета. Сокета при этом нет:
--- запрос отдаётся в обработчик сервера таблицей.
---
--- Источники приходят целиком, а не собираются по установленным
--- пакетам: проверке нужны и те, которых на машине нет вовсе, — ворота,
--- вход, выкладка метрик.
---@param source table Источники панели
---@param httpd table|nil Сервер, к которому подключиться; пусто — двойник
---@return TntAdminPanel
function helper.panel(source, httpd)
    local panels = sources.module('tnt.admin.app.http.panel')
    local built = panels.new(source)
    local server = httpd or { options = { handler = function() end } }

    built.attach(server)

    local panel = {}

    --- Запрос к панели: способ, путь, тело и что положить в запрос сверх.
    ---
    --- Строка запроса выкраивается из пути, как это делает сервер: он
    --- отдаёт путь и строку запроса порознь, и проверка, написавшая их
    --- вместе, иначе теряла бы отбор.
    ---@param method string
    ---@param path string Путь, можно со строкой запроса
    ---@param body string|nil
    ---@param extra table|nil Поля запроса сверх обычных: заголовки, адрес клиента
    ---@return table
    function panel.ask(method, path, body, extra)
        local given = extra or {}
        local address, search = tostring(path):match('^([^?]*)%??(.*)$')

        -- Заголовки отдаются сборке запроса, а не кладутся поверх неё:
        -- длину тела считает она, и заменённые целиком заголовки унесли
        -- бы её с собой.
        local request = helper.incoming({
            method = method,
            path = address,
            query = search,
            body = body,
            headers = given.headers,
        })

        for key, value in pairs(given) do
            if key ~= 'headers' then
                request[key] = value
            end
        end

        return server.options.handler(server, request)
    end

    --- Запрос к панели как есть: тем, что отдаёт `http.server`.
    ---
    --- Нужен там, где запрос собирают по-своему: тело сверх предела,
    --- чтение, которое бросает, заголовки без головы.
    ---@param request table
    ---@return table
    function panel.serve(request)
        return server.options.handler(server, request)
    end

    --- Пути, которые панель обслуживает.
    ---
    --- Перечисляются только именованные маршруты: страницы и раздача
    --- файлов — не договор с клиентом API, и описывать их в перечне
    --- нечего.
    ---@return string[]
    function panel.routes()
        local paths, seen = {}, {}

        for _, route in ipairs(built.routes()) do
            if route.name ~= nil and not seen[route.pattern] then
                seen[route.pattern] = true

                table.insert(paths, route.pattern)
            end
        end

        table.sort(paths)

        return paths
    end

    return panel
end

--- Тело ответа строкой: поток обходится так же, как его обходит сервер.
---
--- Выгрузка журнала и страница журнала отвечают потоком, а проверке
--- нужно то, что увидит клиент, — и обходить тело ей надо так же, как
--- сервер, иначе отказ посреди потока проверка бы не увидела.
---@param response table
---@return string
function helper.drained(response)
    if type(response.body) ~= 'function' then
        return response.body
    end

    local parts = {}

    for _, part in response.body do
        table.insert(parts, part)
    end

    return table.concat(parts)
end

--- Убирает загруженные экземпляры и возвращает то, что они вытеснили.
function helper.unload()
    sources.unload(helper.MODULES)
end

--- Поднимает панель на настоящем порту: сервер на петле, порт случайный.
---
--- Толчок обзора проверяется только так: соединение WebSocket забирает
--- сокет у сервера, и запросом-таблицей его не открыть.
---@param source table Источники панели
---@return table server Сервер; гасит его `helper.close`
---@return integer port
function helper.serve(source)
    local server = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false })

    helper.panel(source, server)
    server:start()

    return server, server.tcp_server:name().port
end

--- Гасит сервер панели, если его поднимали, и убирает экземпляры.
---@param server table|nil
function helper.close(server)
    if server ~= nil then
        server:stop()
    end

    helper.unload()
end

--- Клиент Centrifugo строками JSON: соединение, следующее сообщение узла
--- и команда с ответом. Команды пишутся так, как их шлёт `centrifuge-js`.
---
--- WebSocket клиента — установленный `tnt-websocket`, обычным `require`:
--- он сторона проверки, а не панели, и его код здесь не проверяется.

--- Открывает соединение WebSocket с узлом.
---@param url string
---@return any ws
function helper.dial(url)
    local ws, err = require('tnt.websocket').connect(url, { timeout = 2 })

    if ws == nil then
        error(tostring(err), 2)
    end

    return ws
end

--- Следующее сообщение сервера, разобранное из JSON; ping — пустая таблица.
---@param ws any
---@param timeout number|nil
---@return any message
---@return any err
function helper.heard(ws, timeout)
    local message, err = ws:receive(timeout or 2)

    if message == nil then
        return nil, err
    end

    return json.decode(message.data)
end

--- Шлёт команды строкой и ждёт одного ответа.
---@param ws any
---@param text string Команды JSON через перевод строки
---@return any
function helper.call(ws, text)
    ws:send(text)

    return (helper.heard(ws))
end

return helper
