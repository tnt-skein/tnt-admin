{{-- Обзор: что с кластером прямо сейчас и что с этим делать.

     Сводка, подсказки, находки и репликасеты — в одном порядке: сверху
     то, на что смотрят первым, снизу то, в чём разбираются. --}}
@extends('layout')

@section('title', 'Обзор')

@section('content')
@include('partials.heading', { title = 'Обзор', note = 'обход ' .. tostring(cluster.generation or '—') })

<div class="row g-3 mb-4">
    @include('partials.tile', {
        title = 'Узлов',
        value = cluster.summary.total or 0,
        note = 'репликасетов ' .. tostring(cluster.summary.replicasets or 0),
    })
    @include('partials.tile', {
        title = 'Не отвечают',
        value = cluster.summary.unreachable or 0,
        tone = (cluster.summary.unreachable or 0) > 0 and 'danger' or 'body',
    })
    @include('partials.tile', {
        title = 'Находок',
        value = #issues,
        tone = critical > 0 and 'danger' or (#issues > 0 and 'warning' or 'body'),
        note = critical > 0 and ('важных ' .. critical) or nil,
    })
    @include('partials.tile', { title = 'Выведено', value = cluster.summary.retired or 0 })
</div>

@if (#suggestions > 0)
<h2 class="h6 text-uppercase text-body-secondary mb-2">Что сделать</h2>
<div class="list-group mb-4">
    @for (_, suggestion in ipairs(suggestions))
    <div class="list-group-item d-flex flex-wrap align-items-center gap-2">
        <div class="flex-grow-1">
            <p class="mb-0">{{ format.action(suggestion.action) }}</p>
            <p class="small text-body-secondary mb-0 font-monospace">
                {{ table.concat(suggestion.targets or {}, ', ') }}
            </p>
        </div>
        @include('partials.action-form', { suggestion = suggestion })
    </div>
    @endfor
</div>
@endif

<h2 class="h6 text-uppercase text-body-secondary mb-2">Находки</h2>
@if (#issues > 0)
<ul class="list-group mb-4">
    @for (index, issue in ipairs(issues))
    @if (index <= 8)
    @include('partials.issue', { issue = issue })
    @endif
    @endfor
</ul>
@if (#issues > 8)
<p class="small mb-4"><a href="/issues">ещё {{ #issues - 8 }}</a></p>
@endif
@else
<div class="card mb-4"><div class="card-body">
    @include('partials.empty', { message = 'Находок нет', hint = 'диагностика прошла и ничего не нашла' })
</div></div>
@endif

<h2 class="h6 text-uppercase text-body-secondary mb-2">Репликасеты</h2>
<div class="row g-3">
    @for (_, replicaset in ipairs(cluster.replicasets or {}))
    <div class="col-12 col-md-6 col-xxl-4">
        <div class="card h-100 replicaset-card">
            <div class="card-header d-flex align-items-center justify-content-between gap-2 bg-transparent">
                <span class="fw-semibold font-monospace">{{ replicaset.name }}</span>
                @if (replicaset.healthy)
                <span class="badge text-bg-success">один писатель</span>
                @else
                <span class="badge text-bg-danger">писателей не один</span>
                @endif
            </div>

            @if (replicaset.leader ~= nil and replicaset.active_leader ~= nil and replicaset.leader ~= replicaset.active_leader)
            <div class="card-body py-2 small text-warning">
                назначен <span class="font-monospace">{{ replicaset.leader }}</span>,
                пишет <span class="font-monospace">{{ replicaset.active_leader }}</span>
            </div>
            @endif

            <ul class="list-group list-group-flush">
                @for (_, name in ipairs(replicaset.servers or {}))
                @include('partials.replicaset-server', {
                    name = name,
                    server = cluster.by_name[name],
                    writer = cluster.writers[name],
                })
                @endfor
            </ul>
        </div>
    </div>
    @endfor

    @if (#(cluster.replicasets or {}) == 0)
    <div class="col-12"><div class="card"><div class="card-body">
        @include('partials.empty', {
            message = 'Кластер пуст',
            hint = 'диагностика не подключена или обход ещё не прошёл',
        })
    </div></div></div>
    @endif
</div>
@endsection
