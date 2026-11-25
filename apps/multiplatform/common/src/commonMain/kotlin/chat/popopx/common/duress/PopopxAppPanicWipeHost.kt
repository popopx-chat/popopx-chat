package chat.popopx.common.duress

/**
 * The host the three-tap panic path runs against, for the app that is actually installed.
 *
 * The interface lives in [PopopxPanicWipeHost] and the six steps in [PopopxPanicWipeManager]; this is only the
 * factory, because every real effect is platform-bound: `WorkManager`, `AndroidKeyStore`, `exitProcess`. The tests
 * keep their own host, so nothing here is exercised by `:common:desktopTest` — see the "unverified" note in the
 * commit body.
 *
 * Ruling 2 is what shapes the answers below: the six steps keep their rank, their copy and their journal, and the
 * things they act on are the things that exist on Android. A step whose object does not exist here says so and is
 * recorded as a failure rather than reported as done.
 */
expect fun popopxAppPanicWipeHost(): PopopxPanicWipeHost
