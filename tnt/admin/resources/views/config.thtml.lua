{{-- Конфигурация кластера: что записано в хранилище решений.

     Только просмотр: раскатка правит весь кластер разом, и открытая
     на правку простыня — приглашение сделать это случайно. Правку
     включает узел, объявив её признаком. --}}
@extends('layout')

@section('title', 'Конфигурация')

@section('content')
@include('partials.heading', { title = 'Конфигурация', note = 'как её видит этот узел' })

@if (missing ~= nil)
<div class="alert alert-secondary">{{ missing }}</div>
@else
<div class="card"><div class="card-body p-0">
    <pre class="code-view mb-0 p-3"><code>{{ config.text or config }}</code></pre>
</div></div>
@endif
@endsection
