<?php

use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return response()->json(['service'=>'Avtar POS API','status'=>'ok']);
});
