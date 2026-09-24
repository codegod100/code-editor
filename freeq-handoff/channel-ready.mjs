/** Wait until bot-kit confirms that the requested IRC channel was joined. */
export function waitForChannelJoin(bot, channel, timeoutMs = 15_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`timed out joining FreeQ channel ${channel}`));
    }, timeoutMs);

    bot.on('channelJoined', (joinedChannel) => {
      if (joinedChannel !== channel) return;
      clearTimeout(timer);
      resolve();
    });
  });
}
