/// A single video that can be sent to a DLNA media renderer.
///
/// The TV playurl endpoint requires a cid, an object id and its UGC/PGC type.
/// We keep the queue independent of the video page so it can continue playing
/// without changing the phone's own playback position.
class CastQueueItem {
  const CastQueueItem({
    required this.cid,
    required this.objectId,
    required this.playurlType,
    required this.title,
    this.durationSeconds,
  });

  final int cid;
  final int objectId;
  final int playurlType;
  final String title;
  final int? durationSeconds;
}

/// Play sequentially, stopping after the final item.
class CastQueue {
  const CastQueue({
    required this.items,
    required this.initialIndex,
    this.quality,
  });

  final List<CastQueueItem> items;
  final int initialIndex;
  final int? quality;

  bool get hasNext => initialIndex < items.length - 1;
}
