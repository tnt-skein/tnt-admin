{{-- Находки: что диагностика считает неправильным и что предлагает.

     Подсказка стоит рядом со своей находкой, а не отдельным списком:
     оператор читает «узел не отвечает» и тут же видит кнопку. --}}
@extends('layout')

@section('title', 'Находки')

@section('content')
@include('partials.heading', { title = 'Находки', note = 'всего ' .. #issues })

<div class="btn-group btn-group-sm mb-3" role="group" aria-label="Уровень">
    @for (_, item in ipairs(levels))
    <a class="btn btn-outline-secondary {{ item.name == level and 'active' or '' }}"
       href="/issues?level={{ item.name }}">
        {{ item.title }}
        <span class="text-body-secondary">
            {{ item.name == 'all' and #issues or (counts[item.name] or 0) }}
        </span>
    </a>
    @endfor
</div>

<div class="card">
    @if (#shown > 0)
    <ul class="list-group list-group-flush">
        @for (_, issue in ipairs(shown))
        @include('partials.issue', { issue = issue, advice = advice[issue.server] })
        @endfor
    </ul>
    @else
    <div class="card-body">
        @include('partials.empty', {
            message = #issues > 0 and 'Под отбор ничего не попало' or 'Находок нет',
            hint = #issues > 0 and 'выберите другой уровень' or 'диагностика прошла и ничего не нашла',
        })
    </div>
    @endif
</div>
@endsection
