// The owner retains and awaits its worker. Cancelling the owner cancels the worker,
// and the await does not finish until the worker has actually exited.
extension Task where Failure == Error {
    var cancellableValue: Success {
        get async throws {
            try await withTaskCancellationHandler {
                try await value
            } onCancel: {
                cancel()
            }
        }
    }
}
