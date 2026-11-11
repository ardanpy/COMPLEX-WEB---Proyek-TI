<?php

use App\Http\Controllers\AdminController;
use App\Http\Controllers\AuthController;
use App\Http\Controllers\GuestController;
use App\Http\Controllers\HomeController;
use App\Http\Controllers\SecurityController;
use Illuminate\Support\Facades\Route;

// ---- Publik (pra-login) ----
Route::post('/auth/login', [AuthController::class, 'login'])->middleware('throttle:login');
Route::post('/auth/otp/resend', [AuthController::class, 'otpResend'])->middleware('throttle:otp');
Route::post('/auth/forgot', [AuthController::class, 'forgot'])->middleware('throttle:otp');
Route::post('/auth/otp/verify', [AuthController::class, 'otpVerify'])->middleware('throttle:login');
Route::post('/auth/set-password', [AuthController::class, 'setPassword'])->middleware('throttle:login');

// ---- Tamu (bukan akun) ----
Route::post('/guest/start', [GuestController::class, 'start'])->middleware('throttle:guest-start');
Route::get('/guest/home', [GuestController::class, 'home']);
Route::post('/guest/report', [GuestController::class, 'report'])->middleware('throttle:guest-report');
Route::post('/guest/report/{id}/end', [GuestController::class, 'end']);

// ---- Semua role berakun ----
Route::middleware('session.auth')->group(function () {
    Route::get('/auth/me', [AuthController::class, 'me']);
    Route::post('/auth/logout', [AuthController::class, 'logout']);
    Route::post('/auth/change-password', [AuthController::class, 'changePassword'])->middleware('throttle:otp');
    Route::get('/home', [HomeController::class, 'index']);
});

// ---- Security (satpam) ----
Route::middleware('session.auth:security')->group(function () {
    Route::get('/security/attendance/status', [SecurityController::class, 'status']);
    Route::post('/security/attendance/check-in', [SecurityController::class, 'checkIn']);
    Route::post('/security/attendance/check-out', [SecurityController::class, 'checkOut']);
    Route::get('/security/attendance', [SecurityController::class, 'attendance']);
    Route::patch('/security/reports/{id}/status', [SecurityController::class, 'setReportStatus']);
    Route::get('/security/guests', [SecurityController::class, 'guests']);
});
Route::middleware('session.auth:security,admin')->group(function () {
    Route::get('/security/reports', [SecurityController::class, 'reports']);
    Route::get('/security/reports/{id}', [SecurityController::class, 'report']);
    Route::get('/files/attendance/{key}', [SecurityController::class, 'attendancePhoto']);
});

// ---- Admin ----
Route::middleware('session.auth:admin')->prefix('admin')->group(function () {
    Route::post('/users', [AdminController::class, 'createUser']);
    Route::get('/users', [AdminController::class, 'users']);
    Route::post('/users/{id}/reset-password', [AdminController::class, 'resetPassword']);
    Route::patch('/users/{id}/status', [AdminController::class, 'setStatus']);
    Route::get('/attendance', [AdminController::class, 'attendance']);
    Route::get('/report-log', [AdminController::class, 'reportLog']);
});
