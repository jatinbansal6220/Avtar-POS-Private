/// Cooperative cancellation: abort rendering/network work and cancel only this
/// job in the Windows spooler. Paper already physically printed cannot be undone.
class PrintJob {
  bool cancelled=false;
  Future<void> Function()? onCancel;
  void check(){if(cancelled)throw const PrintCancelled();}
  Future<void> cancel() async {cancelled=true;await onCancel?.call();}
}
class PrintCancelled implements Exception {
  const PrintCancelled();
  @override String toString()=>'Printing cancelled';
}
