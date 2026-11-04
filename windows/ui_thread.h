#ifndef FLUTTER_PLUGIN_VITAL_BLUETOOTH_UI_THREAD_H_
#define FLUTTER_PLUGIN_VITAL_BLUETOOTH_UI_THREAD_H_

#include <windows.h>

#include <coroutine>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>

namespace vital_bluetooth {

// Runs work on the thread that created it (the Flutter UI thread).
//
// WinRT Bluetooth callbacks arrive on thread-pool threads, but Flutter
// channels must only be used on the UI thread. Post() queues a task and
// wakes a message-only window on the UI thread, which runs the queue.
// After Close() nothing more runs, so late callbacks can't reach a plugin
// that is gone.
class UiThread {
 public:
  UiThread();
  ~UiThread();

  UiThread(const UiThread&) = delete;
  UiThread& operator=(const UiThread&) = delete;

  // Safe to call from any thread.
  void Post(std::function<void()> task);

  void Close();

 private:
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  void RunQueued();

  HWND window_ = nullptr;
  std::mutex mutex_;
  std::deque<std::function<void()>> queue_;
  bool closed_ = false;
};

// co_await ResumeOnUi{ui} continues the coroutine on the UI thread. If the
// UiThread is closed, the coroutine never continues.
struct ResumeOnUi {
  std::shared_ptr<UiThread> ui;

  bool await_ready() const noexcept { return false; }
  void await_suspend(std::coroutine_handle<> handle) const {
    ui->Post([handle] { handle.resume(); });
  }
  void await_resume() const noexcept {}
};

}  // namespace vital_bluetooth

#endif  // FLUTTER_PLUGIN_VITAL_BLUETOOTH_UI_THREAD_H_
