export class AppError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status = 422,
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "AppError";
  }
}

export function asAppError(error: unknown): AppError {
  return error instanceof AppError
    ? error
    : new AppError("INTERNAL_ERROR", "Something went wrong while opening this video. Please try again.", 500);
}
