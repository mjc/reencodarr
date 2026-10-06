// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let Hooks = {}

window.addEventListener("click", event => {
  const el = event.target instanceof Element ? event.target.closest("[data-confirm]") : null

  if (el && !window.confirm(el.dataset.confirm)) {
    event.preventDefault()
    event.stopImmediatePropagation()
  }
}, true)

Hooks.TimezoneHook = {
  mounted() {
    this.setTimezone();
  },
  reconnected() {
    this.setTimezone();
  },
  setTimezone() {
    let timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    this.pushEvent("set_timezone", { timezone: timezone });
  }
}

Hooks.RangeSelectCheckboxes = {
  mounted() {
    this.lastClickedId = null
    this.handleClick = (event) => {
      const checkbox = event.target.closest("input[data-range-select='video']")
      if (!checkbox) return

      event.preventDefault()

      const id = checkbox.dataset.id
      const shouldSelect = (!checkbox.checked).toString()

      if (event.shiftKey && this.lastClickedId) {
        this.pushEvent("select_range", {
          start_id: this.lastClickedId,
          end_id: id,
          selected: shouldSelect
        })
      } else {
        this.pushEvent("toggle_select", {id})
      }

      this.lastClickedId = id
    }

    this.el.addEventListener("click", this.handleClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  }
}

const clearStoredLongPollFallback = () => {
  for (const store of [window.sessionStorage, window.localStorage]) {
    try {
      store?.removeItem("phx:fallback:LongPoll")
    } catch (_) {
    }
  }
}

const shouldPersistLongPollFallback = async () => {
  try {
    const response = await fetch("/", {
      cache: "no-store",
      credentials: "same-origin",
      redirect: "manual"
    })

    if (response.type === "opaqueredirect") return false
    if ([401, 403, 407, 419, 440].includes(response.status)) return false
    if (response.status >= 300 && response.status < 400) return false

    return response.ok
  } catch (_) {
    return false
  }
}

const sessionStorageWithoutTransportFallback = {
  getItem(key) {
    return key.startsWith("phx:fallback:") ? null : window.sessionStorage.getItem(key)
  },
  setItem(key, value) {
    if (key.startsWith("phx:fallback:")) {
      shouldPersistLongPollFallback().then(shouldStore => {
        if (shouldStore) {
          window.sessionStorage.setItem(key, value)
        }
      })
    } else {
      window.sessionStorage.setItem(key, value)
    }
  },
  removeItem(key) {
    window.sessionStorage.removeItem(key)
  }
}

clearStoredLongPollFallback()

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// Use embedded socket for iframe pages
let socketUrl = window.location.pathname.startsWith("/embed/") ? "/embed/live" : "/live"
let liveSocket = new LiveSocket(socketUrl, Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
  sessionStorage: sessionStorageWithoutTransportFallback
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
