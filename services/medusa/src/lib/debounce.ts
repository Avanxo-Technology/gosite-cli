// A trailing debouncer: every call resets the timer, so a burst of events
// (a bulk import) becomes one action. Used by the purge subscriber so editing
// ten products does not fire ten cache purges.
export function createDebouncer(ms: number, fn: () => void | Promise<void>) {
  let timer: ReturnType<typeof setTimeout> | undefined
  return function schedule(): void {
    if (timer) {
      clearTimeout(timer)
    }
    timer = setTimeout(() => {
      timer = undefined
      void fn()
    }, ms)
    // Do not keep the process alive for a pending purge.
    timer.unref?.()
  }
}
