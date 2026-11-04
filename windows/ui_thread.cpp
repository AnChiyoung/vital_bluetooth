#include "ui_thread.h"

#include <utility>

namespace vital_bluetooth {

namespace {

constexpr wchar_t kWindowClass[] = L"VitalBluetoothUiThread";
constexpr UINT kRunQueue = WM_APP + 0x0B1E;

void RegisterWindowClassOnce() {
  static bool registered = false;
  if (registered) return;
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = DefWindowProcW;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kWindowClass;
  RegisterClassW(&window_class);
  registered = true;
}

}  // namespace

UiThread::UiThread() {
  RegisterWindowClassOnce();
  window_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                            nullptr, GetModuleHandle(nullptr), nullptr);
  if (window_ != nullptr) {
    SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    SetWindowLongPtrW(window_, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(&UiThread::WindowProc));
  }
}

UiThread::~UiThread() { Close(); }

void UiThread::Post(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_ || window_ == nullptr) return;
    queue_.push_back(std::move(task));
  }
  PostMessageW(window_, kRunQueue, 0, 0);
}

void UiThread::Close() {
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return;
    closed_ = true;
    queue_.clear();
    window = window_;
    window_ = nullptr;
  }
  if (window != nullptr) DestroyWindow(window);
}

void UiThread::RunQueued() {
  while (true) {
    std::function<void()> task;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (closed_ || queue_.empty()) return;
      task = std::move(queue_.front());
      queue_.pop_front();
    }
    task();
  }
}

// static
LRESULT CALLBACK UiThread::WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message == kRunQueue) {
    auto* self =
        reinterpret_cast<UiThread*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (self != nullptr) self->RunQueued();
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

}  // namespace vital_bluetooth
