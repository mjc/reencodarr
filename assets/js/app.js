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

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let Hooks = {}

const isInitialPageLoadEvent = (event) => event?.detail?.kind === "initial"

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

Hooks.DashboardAnimations = {
  mounted() {
    this.readyClass = "dashboard-animations-ready"

    this.onWindowLoad = () => this.scheduleReady()
    this.onPageLoadingStart = (event) => {
      if (isInitialPageLoadEvent(event)) return
      this.clearReady()
    }
    this.onPageLoadingStop = (event) => {
      if (isInitialPageLoadEvent(event)) return
      this.scheduleReady()
    }

    if (document.readyState === "complete") {
      this.scheduleReady()
    } else {
      window.addEventListener("load", this.onWindowLoad, {once: true})
    }

    window.addEventListener("phx:page-loading-start", this.onPageLoadingStart)
    window.addEventListener("phx:page-loading-stop", this.onPageLoadingStop)
  },

  scheduleReady() {
    if (this.idleCallback && "cancelIdleCallback" in window) {
      window.cancelIdleCallback(this.idleCallback)
    }

    if (this.readyTimeout) {
      clearTimeout(this.readyTimeout)
    }

    const markReady = () => {
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          if (this.el.isConnected) {
            this.el.classList.add(this.readyClass)
          }
        })
      })
    }

    if ("requestIdleCallback" in window) {
      this.idleCallback = window.requestIdleCallback(markReady, {timeout: 1500})
    } else {
      this.readyTimeout = setTimeout(markReady, 150)
    }
  },

  clearReady() {
    this.el.classList.remove(this.readyClass)
  },

  destroyed() {
    this.clearReady()

    window.removeEventListener("phx:page-loading-start", this.onPageLoadingStart)
    window.removeEventListener("phx:page-loading-stop", this.onPageLoadingStop)
    window.removeEventListener("load", this.onWindowLoad)

    if (this.idleCallback && "cancelIdleCallback" in window) {
      window.cancelIdleCallback(this.idleCallback)
      this.idleCallback = null
    }

    if (this.readyTimeout) {
      clearTimeout(this.readyTimeout)
      this.readyTimeout = null
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// Use embedded socket for iframe pages
let socketUrl = window.location.pathname.startsWith("/embed/") ? "/embed/live" : "/live"
let liveSocket = new LiveSocket(socketUrl, Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", event => {
  if (isInitialPageLoadEvent(event)) return
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", event => {
  if (isInitialPageLoadEvent(event)) return
  topbar.hide()
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
