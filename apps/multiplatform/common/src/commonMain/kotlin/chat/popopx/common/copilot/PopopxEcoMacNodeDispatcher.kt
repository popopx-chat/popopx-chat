package chat.popopx.common.copilot

import chat.popopx.common.discover.PopopxNodeCommand
import chat.popopx.common.discover.PopopxNodeServiceId
import chat.popopx.common.discover.PopopxNodeWire

/**
 * `node.dispatch_task` against the transport the app already has.
 *
 * A node command travels as an invisible text to a paired service account
 * ([PopopxNodeCommand]), so the assistant may not invent either end of it: the service must be one
 * the user has paired, and the action must be one that service's own menu offers
 * ([PopopxNodeServiceId.menuActions]), which is the set the host accepts. Anything else is refused
 * here, before a sender is consulted, so "the model named a service" can never become "the app sent
 * a message to an account".
 *
 * This is also why the payload is fixed at `{}`: the engine's `payload_ref` is a local file
 * reference, and the host documents that it cannot know offline which token is meaningful, so a
 * reference is never turned into content and never leaves the device.
 */
class PopopxEcoMacNodeDispatcher(
  private val pairedServices: () -> List<PopopxNodeServiceId>,
  private val send: (PopopxNodeCommand) -> Boolean = { false },
) {
  /** What the user sees: the refusal is a sentence, and a null is not. */
  sealed interface Result {
    /** The command was accepted by the transport, which is the pair's encrypted queue. */
    data class Queued(val command: PopopxNodeCommand) : Result

    data class Rejected(val reason: String) : Result
  }

  fun dispatch(task: EcoDispatchTask): Result {
    val service = task.service ?: return Result.Rejected("no Mac Node service was named")
    val action = task.action ?: return Result.Rejected("no Mac Node action was named")
    val paired = pairedServices()
    if (paired.none { it == service }) {
      return Result.Rejected("${service.rawValue} is not paired on this device")
    }
    if (service.menuActions.none { it.action == action }) {
      return Result.Rejected("$action is not an action ${service.rawValue} offers")
    }
    val command = PopopxNodeCommand(service, action, "{}")
    if (!PopopxNodeWire.isAccepted(command)) return Result.Rejected("the command is longer than the node accepts")
    return if (send(command)) Result.Queued(command) else Result.Rejected("the node is not reachable right now")
  }
}
