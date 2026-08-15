/// Every repository returns one of these three states — per the build
/// addendum's error-handling rule — instead of throwing raw exceptions past
/// the repository boundary. UI code pattern-matches on this rather than
/// wrapping every repository call in its own try/catch.
///
/// Note: the services carried over from the original scaffold (BibleRepository,
/// GroqService, TtsService, RadioService) still throw exceptions directly,
/// which is the pre-existing pattern in this codebase and not something this
/// file silently fixes everywhere at once — retrofitting all four is a
/// separate, explicit follow-up so each gets tested on its own, not bundled
/// into an unrelated change. GamesRepository below is the first real user of
/// this type; new repositories should use it from the start.
sealed class Result<T> {
  const Result();

  const factory Result.loading() = ResultLoading<T>;
  const factory Result.success(T data) = ResultSuccess<T>;
  const factory Result.failure(AppFailure failure) = ResultFailure<T>;
}

class ResultLoading<T> extends Result<T> {
  const ResultLoading();
}

class ResultSuccess<T> extends Result<T> {
  const ResultSuccess(this.data);
  final T data;
}

class ResultFailure<T> extends Result<T> {
  const ResultFailure(this.failure);
  final AppFailure failure;
}

/// A failure that's safe to show directly in the UI ([message]) plus a
/// separate [debugDetail] for Logger — never the reverse, so a stack trace
/// never accidentally ends up in front of a user.
class AppFailure {
  const AppFailure(
      {required this.message, this.debugDetail, this.retryable = true});
  final String message;
  final String? debugDetail;
  final bool retryable;
}
