package chat.popopx.common.helpers

import android.net.*
import android.util.Log
import androidx.core.content.getSystemService
import chat.popopx.common.model.ChatModel.controller
import chat.popopx.common.model.UserNetworkInfo
import chat.popopx.common.model.UserNetworkType
import chat.popopx.common.network.PopopxRelayLatency
import chat.popopx.common.platform.*
import chat.popopx.common.views.helpers.withBGApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay

class NetworkObserver {
  private var prevInfo: UserNetworkInfo? = null

  // When having both mobile and Wi-Fi networks enabled with Wi-Fi being active, then disabling Wi-Fi, network reports its offline (which is true)
  // but since it will be online after switching to mobile, there is no need to inform backend about such temporary change.
  // But if it will not be online after some seconds, report it and apply required measures
  private var noNetworkJob = Job() as Job
  private val networkCallback = object: ConnectivityManager.NetworkCallback() {
    override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) = networkCapabilitiesChanged(networkCapabilities)
    override fun onLost(network: Network) = networkLost()
  }
  private val connectivityManager: ConnectivityManager? = androidAppContext.getSystemService()

  fun restartNetworkObserver() {
    if (connectivityManager == null) {
      Log.e(TAG, "Connectivity manager is unavailable, network observer is disabled")
      val info = UserNetworkInfo(
        networkType = UserNetworkType.OTHER,
        online = true,
      )
      prevInfo = info
      setNetworkInfo(info)
      return
    }
    try {
      connectivityManager.unregisterNetworkCallback(networkCallback)
    } catch (e: Exception) {
      // do nothing
    }
    val initialCapabilities = connectivityManager.getNetworkCapabilities(connectivityManager.activeNetwork)
    if (initialCapabilities != null) {
      networkCapabilitiesChanged(initialCapabilities)
    } else {
      networkLost()
    }
    try {
      connectivityManager.registerDefaultNetworkCallback(networkCallback)
    } catch (e: Exception) {
      Log.e(TAG, "Error registering network callback: ${e.stackTraceToString()}")
    }
  }

  private fun networkCapabilitiesChanged(capabilities: NetworkCapabilities) {
    connectivityManager ?: return
    val info = UserNetworkInfo(
      networkType = networkTypeFromCapabilities(capabilities),
      online = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
    )
    if (prevInfo != info) {
      val prev = prevInfo
      prevInfo = info
      setNetworkInfo(info)
      // A round measured over Wi-Fi says nothing about cellular, so an interface change voids the
      // cache rather than letting 你的服务器 rank on a route that no longer exists.
      if (prev != null && prev.networkType != info.networkType) {
        PopopxRelayLatency.shared.invalidate()
      }
      reconnectOnPathChange(prev, info)
    }
  }

  /** Reconnect the SMP/XFTP connections on an edge the agent cannot see for itself.
   *
   * What [setNetworkInfo] delivers is `apiSetNetworkInfo`, which in the core writes a TVar behind
   * `userOfflineDelay` and reconnects nothing (the same `Agent.hs:741-751` the iOS twin cites).
   * `reconnect_all_servers` (Agent.hs:753-757) is the command that redials, so without it a device
   * moving Wi-Fi -> cellular waits for the ordinary retry timer while the UI already shows a network.
   *
   * Skipped for the first reading — a starting app connects by itself — and for a transition to
   * offline, where there is nothing to reconnect to.
   */
  private fun reconnectOnPathChange(prev: UserNetworkInfo?, info: UserNetworkInfo) {
    if (prev == null || !info.online) return
    if (prev.online && prev.networkType == info.networkType) return
    // The interface is up before the route works; redialling on the same callback turn usually fails,
    // and the 3s loss debounce above is why an offline edge is left to its own timing.
    withBGApi {
      delay(RECONNECT_SETTLE_MS)
      if (prevInfo != info) return@withBGApi
      if (controller.hasChatCtrl()) {
        try {
          controller.reconnectAllServers(null)
        } catch (e: Exception) {
          // A failed redial is not worth an alert: the ordinary retry timer still runs. It is worth a
          // log line, because "it did not reconnect" is the question asked of every switch report.
          Log.e(TAG, "reconnectOnPathChange failed: ${e.stackTraceToString()}")
        }
      }
    }
  }

  private fun networkLost() {
    Log.d(TAG, "Network changed: lost")
    val none = UserNetworkInfo(networkType = UserNetworkType.NONE, false)
    prevInfo = none
    setNetworkInfo(none)
  }

  private fun setNetworkInfo(info: UserNetworkInfo) {
    getWakeLock(timeout = 180000)
    Log.d(TAG, "Network changed: $info")
    noNetworkJob.cancel()
    if (info.online) {
      withBGApi {
        if (controller.hasChatCtrl() && controller.apiSetNetworkInfo(info)) {
          chatModel.networkInfo.value = info
        }
      }
    } else {
      noNetworkJob = withBGApi {
        delay(3000)
        if (controller.hasChatCtrl() && controller.apiSetNetworkInfo(info)) {
          chatModel.networkInfo.value = info
        }
      }
    }
  }

  private fun networkTypeFromCapabilities(capabilities: NetworkCapabilities): UserNetworkType = when {
    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> UserNetworkType.ETHERNET
    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> UserNetworkType.WIFI
    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> UserNetworkType.CELLULAR
    else -> UserNetworkType.OTHER
  }

  companion object {
    val shared = NetworkObserver()

    /** How long to let a new path settle before redialling. Mirrors `reconnectSettle` in the iOS
     * NetworkObserver; a reconnect fired on the callback turn itself races the route into coming up. */
    private const val RECONNECT_SETTLE_MS = 300L
  }
}
