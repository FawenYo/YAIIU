# Uploading asset resources in the background | Apple Developer Documentation

-   [PhotoKit](/documentation/photokit)
-   [Photos](/documentation/photos)
-   Uploading asset resources in the background

Article

# Uploading asset resources in the background

Enable reliable cloud backup for photo library assets with background processing.

## [Overview](/documentation/photokit/uploading-asset-resources-in-the-background#Overview)

PhotoKit’s Background Resource Upload extension enables apps to deliver seamless cloud backup experiences. The system manages uploads on your app’s behalf, processing them in the background even when people switch to other apps or lock their devices. The system calls your extension to process uploads when conditions allow, scheduling work based on factors such as network availability, power state, and device activity.

The async [`PHBackgroundResourceUploadJobExtension`](/documentation/photos/phbackgroundresourceuploadjobextension) protocol is available on iOS 27.0, macOS 27.0, and Mac Catalyst 27.0. On iOS 26.1, the feature is available through [`PHBackgroundResourceUploadExtension`](/documentation/photos/phbackgroundresourceuploadextension), which is deprecated as of iOS 27.

## [Create and configure the extension target](/documentation/photokit/uploading-asset-resources-in-the-background#Create-and-configure-the-extension-target)

To add an upload extension to your app, begin by adding a new target:

1.  In Xcode, choose File > New > Target.
    
2.  In the dialog, select the iOS tab, choose the Generic Extension template, and click Next.
    
3.  Specify a name for your extension, such as `BackgroundUploadExtension`.
    
4.  Click Finish.
    

Open your extension’s main Swift file and replace its contents with a class that adopts the [`PHBackgroundResourceUploadJobExtension`](/documentation/photos/phbackgroundresourceuploadjobextension) protocol:

```
import Photos
import ExtensionFoundation
import Synchronization

@main
class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension {
    required init() {}

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        // Process upload jobs.
        return .completed
    }

    func willTerminate() async {
        // Prepare for termination.
    }
}
```

The extension conforms to this protocol by adopting the following methods:

[`processJobs()`](/documentation/photos/phbackgroundresourceuploadjobextension/processjobs\(\))

Performs asset resource uploads by creating and managing upload jobs.

[`willTerminate()`](/documentation/photos/phbackgroundresourceuploadjobextension/willterminate\(\))

Handles notification of the extension’s termination to interrupt processing and perform cleanup.

In the Info pane in Xcode, make the following changes:

-   Expand the `EXAppExtensionAttributes` dictionary and change its `EXExtensionPointIdentifier` value to `com.apple.photos.background-upload`. This identifier registers your extension with the system’s background upload infrastructure.
    
-   Add a new top-level key named `BackgroundUploadURLBase` of type `String`, and set its value to the base URL for your upload server, such as `https://api.example.com`. The system requires this key for network access validation.
    

![A screenshot of the required Info pane entries the asset resource upload extension must provide.](https://docs-assets.developer.apple.com/published/4a96ece55519bdc74bff5f13f84687b9/upload-extension-plist.png)

## [Enable the extension](/documentation/photokit/uploading-asset-resources-in-the-background#Enable-the-extension)

Before the system can call your extension, your host app must explicitly enable it by calling [`setUploadJobExtensionEnabled(_:)`](/documentation/photos/phphotolibrary/setuploadjobextensionenabled\(_:\)) on the shared photo library instance. Your app must have full library access before enabling the extension. Call [`requestAuthorization(for:handler:)`](/documentation/photos/phphotolibrary/requestauthorization\(for:handler:\)) with the `.readWrite` access level and verify the status is `.authorized`.

The following example shows how to enable the background upload extension in your host app:

```
let library = PHPhotoLibrary.shared()

// Request full library access first.
let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
guard status == .authorized else {
    // Handle unauthorized state.
    return
}

// Enable the upload extension.
do {
    try library.setUploadJobExtensionEnabled(true)
    print("Extension enabled successfully")
} catch {
    print("Failed to enable extension: \(error)")
}
```

Check the [`uploadJobExtensionEnabled`](/documentation/photos/phphotolibrary/uploadjobextensionenabled) property to verify the extension’s current state. To stop background processing, call the [`setUploadJobExtensionEnabled(_:)`](/documentation/photos/phphotolibrary/setuploadjobextensionenabled\(_:\)) method with a value of `false`.

## [Process upload jobs](/documentation/photokit/uploading-asset-resources-in-the-background#Process-upload-jobs)

The system calls your extension’s [`processJobs()`](/documentation/photos/phbackgroundresourceuploadjobextension/processjobs\(\)) method when upload work is available. A typical implementation first retries failed uploads, then acknowledges completed or failed uploads to free resources, and finally creates new upload jobs for unprocessed assets.

[`processJobs()`](/documentation/photos/phbackgroundresourceuploadjobextension/processjobs\(\)) is declared `async` but does not require asynchronous work. An extension with synchronous upload logic can return a value directly. When calling async helpers such as [`data(for:)`](/documentation/Foundation/URLSession/data\(for:\)), use `await` as usual.

```
func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
    do {
        // Retry any failed jobs.
        try await retryFailedJobs()

        // Acknowledge completed jobs to free up the inflight job limit.
        try await acknowledgeCompletedJobs()

        // Create new upload jobs for unprocessed assets.
        try await createNewUploadJobs()

        return .completed
    } catch PHPhotosError.limitExceeded {
        // Reached the inflight job limit; return `.processing`.
        return .processing
    } catch {
        // Other errors.
        return .failure
    }
}
```

After performing your processing, return an appropriate [`PHBackgroundResourceUploadProcessingResult`](/documentation/photos/phbackgroundresourceuploadprocessingresult) value to indicate your extension’s state:

[`PHBackgroundResourceUploadProcessingResult.completed`](/documentation/photos/phbackgroundresourceuploadprocessingresult/completed)

Your extension finishes processing all jobs and no pending work remains. The system enters monitoring mode for library changes.

[`PHBackgroundResourceUploadProcessingResult.processing`](/documentation/photos/phbackgroundresourceuploadprocessingresult/processing)

Work is in progress. The system calls [`processJobs()`](/documentation/photos/phbackgroundresourceuploadjobextension/processjobs\(\)) again to continue processing. Return this value during initial library uploads when you have remaining assets to process.

[`PHBackgroundResourceUploadProcessingResult.failure`](/documentation/photos/phbackgroundresourceuploadprocessingresult/failure)

An unrecoverable error occurs. The system logs the error and may retry later.

Handle [`limitExceeded`](/documentation/photos/phphotoserror-swift.struct/limitexceeded) by returning `.processing` to pause until space becomes available. When [`fetchPersistentChanges(since:)`](/documentation/photos/phphotolibrary/fetchpersistentchanges\(since:\)) throws [`persistentChangeTokenExpired`](/documentation/photos/phphotoserror-swift.struct/persistentchangetokenexpired), the system has pruned history past your saved token; discard the saved token, return `.processing`, and re-sync on the next invocation. For other errors, log the details and return `.failure`.

## [Retry failed jobs](/documentation/photokit/uploading-asset-resources-in-the-background#Retry-failed-jobs)

Network issues or temporary server problems can cause upload failures. Your extension can retry jobs in the `.failed` state that haven’t exceeded the retry limit. Retrying jobs recovers from transient errors without manual intervention.

Inspect the underlying error using the [`error`](/documentation/photos/phassetresourceuploadjob/error) property and access any headers your server returns using the [`responseHeaderFields`](/documentation/photos/phassetresourceuploadjob/responseheaderfields).

Fetch retry-able jobs by calling the [`fetchJobs(action:options:)`](/documentation/photos/phassetresourceuploadjob/fetchjobs\(action:options:\)) method with the [`PHAssetResourceUploadJob.Action.retry`](/documentation/photos/phassetresourceuploadjob/action/retry) action, shown here:

```
private func retryFailedJobs() async throws {
    let library = PHPhotoLibrary.shared()
    let retryableJobs = PHAssetResourceUploadJob.fetchJobs(action: .retry, options: nil)

    for i in 0..<retryableJobs.count {
        let job = retryableJobs.object(at: i)

        // Inspect the error to determine whether to retry or acknowledge the upload job.
        if let error = job.error as? URLError,
            error.code == .badServerResponse ||
            error.code == .userAuthenticationRequired {
            // Permanent error; acknowledge instead of retrying.
            try await library.performChanges {
                guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else {
                    return
                }
                request.acknowledge()
            }
            continue
        }

        try await library.performChanges {
            guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else {
                return
            }

            // Option 1: Retry with the original destination.
            request.retry(destination: nil)

            // Option 2: Provide a new destination; for example, with refreshed authorization.
            // let newDestination = buildDestination(forUploadJob: job)
            // request.retry(destination: newDestination)
        }
    }
}
```

Because [`PHFetchResult`](/documentation/photos/phfetchresult) doesn’t conform to [`Sequence`](/documentation/Swift/Sequence), use index-based enumeration instead. All job mutations must occur within a `Photos/PHPhotoLibrary/performChanges(_:)` or [`performChangesAndWait(_:)`](/documentation/photos/phphotolibrary/performchangesandwait\(_:\)) change block.

Inspect the [`error`](/documentation/photos/phassetresourceuploadjob/error) property to distinguish transient network errors from permanent server errors. For transient errors such as timeouts or connection loss, retry the job. For permanent errors such as bad server responses or authentication failures, acknowledge the job instead.

Passing `nil` to [`retry(destination:)`](/documentation/photos/phassetresourceuploadjobchangerequest/retry\(destination:\)) uses the original destination URL. Alternatively, you can retry the job with a different destination. Retrying a job counts toward the inflight job limit. If you’ve reached the limit, the retry throws [`limitExceeded`](/documentation/photos/phphotoserror-swift.struct/limitexceeded). Acknowledge completed jobs to free capacity before retrying.

## [Acknowledge completed jobs](/documentation/photokit/uploading-asset-resources-in-the-background#Acknowledge-completed-jobs)

Jobs that you create consume space in the extension’s inflight job limit. Whether a job succeeds or fails, acknowledge it to free capacity for new uploads.

Before acknowledging a job, inspect the [`responseHeaderFields`](/documentation/photos/phassetresourceuploadjob/responseheaderfields) property to access any response headers returned from your server.

Fetch acknowledgeable jobs by calling the [`fetchJobs(action:options:)`](/documentation/photos/phassetresourceuploadjob/fetchjobs\(action:options:\)) method with the [`PHAssetResourceUploadJob.Action.acknowledge`](/documentation/photos/phassetresourceuploadjob/action/acknowledge) action, shown here:

```
private func acknowledgeCompletedJobs() async throws {
    let library = PHPhotoLibrary.shared()
    let completedJobs = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)

    for i in 0..<completedJobs.count {
        let job = completedJobs.object(at: i)

        // Inspect response headers before acknowledging.
        if let headers = job.responseHeaderFields,
           let resource = PHAssetResource.assetResource(forUploadJob: job) {
            let serverId = headers["x-server-resource-id"]
            recordServerMetadata(for: resource, serverId: serverId)
        }

        try await library.performChanges {
            // Attempt to create a change request, and return early on failure.
            guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
            // Acknowledge the job.
            request.acknowledge()
        }
    }
}
```

After confirming each job’s upload status with your server or local tracking system, acknowledge it by calling the [`acknowledge()`](/documentation/photos/phassetresourceuploadjobchangerequest/acknowledge\(\)) method on the change request. Acknowledging a job removes it from system tracking and frees up space for new jobs. You must acknowledge completed jobs before creating new ones when you reach the inflight limit.

## [Inspect response headers and errors](/documentation/photokit/uploading-asset-resources-in-the-background#Inspect-response-headers-and-errors)

The system copies any response headers returned by your server to the [`responseHeaderFields`](/documentation/photos/phassetresourceuploadjob/responseheaderfields) property for jobs in the [`PHAssetResourceUploadJob.State.succeeded`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/succeeded) or [`PHAssetResourceUploadJob.State.failed`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/failed) state. The system normalizes header field names to lowercase for consistent lookup.

The system populates the [`error`](/documentation/photos/phassetresourceuploadjob/error) property for jobs in the [`PHAssetResourceUploadJob.State.failed`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/failed) state. It provides detailed information about why the upload failed, including network, server, or system errors. The error uses standard [`NSURLErrorDomain`](/documentation/Foundation/NSURLErrorDomain) codes, letting you distinguish transient failures such as timeouts from permanent failures such as authentication errors.

## [Cancel inflight jobs](/documentation/photokit/uploading-asset-resources-in-the-background#Cancel-inflight-jobs)

You can cancel redundant background upload jobs to avoid duplicate uploads. You can only cancel jobs in the [`PHAssetResourceUploadJob.State.registered`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/registered) or [`PHAssetResourceUploadJob.State.pending`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/pending) state.

Fetch cancellable jobs by calling the [`fetchJobs(action:options:)`](/documentation/photos/phassetresourceuploadjob/fetchjobs\(action:options:\)) method with the [`PHAssetResourceUploadJob.Action.process`](/documentation/photos/phassetresourceuploadjob/action/process) action, shown here:

```
private func cancelRedundantJobs() throws {
    let library = PHPhotoLibrary.shared()
    let inProgressJobs = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil)

    for i in 0..<inProgressJobs.count {
        let job = inProgressJobs.object(at: i)

        // Check if this job is redundant. This example checks to see if the resource has already
        // been uploaded with another process.
        guard let resource = PHAssetResource.assetResource(forUploadJob: job),
              isAlreadyUploaded(resource.assetLocalIdentifier) else { continue }

        try library.performChangesAndWait {
            guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
            request.cancel()
        }
    }
}
```

Canceled jobs transition to the [`PHAssetResourceUploadJob.State.cancelled`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/cancelled) state, and the system automatically acknowledges them, so they don’t consume space in the inflight job limit.

## [Create upload jobs](/documentation/photokit/uploading-asset-resources-in-the-background#Create-upload-jobs)

Creating upload jobs queues asset resources for background upload to your server. Each job requires a destination URL request that specifies the upload destination.

If needed, you can use the returned change request job to access the [`placeholderForCreatedAssetResourceUploadJob`](/documentation/photos/phassetresourceuploadjobchangerequest/placeholderforcreatedassetresourceuploadjob) and obtain the local identifier for the job.

Create jobs after acknowledging completed ones and when you detect new assets in the library. Your extension needs a mechanism to identify which assets require upload, typically by maintaining a list of processed asset identifiers.

```
private func createNewUploadJobs() async throws {
    let library = PHPhotoLibrary.shared()

    // Get unprocessed asset resources. Your implementation should query
    // for assets and filter against the uploaded set.
    let resources = getUnprocessedResources(from: library)

    // Return early if there are no resources to process.
    guard !resources.isEmpty else { return }

    for resource in resources {
        try await library.performChanges {
            // Create a URL request for your server.
            let url = URL(string: "https://api.example.com/upload")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"

            // Add authentication.
            request.setValue("YOUR_AUTH_TOKEN", forHTTPHeaderField: "Authorization")

            // Add resource metadata.
            request.setValue(resource.originalFilename, forHTTPHeaderField: "X-Filename")

            // Create the upload job.
            let jobRequest = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(
                destination: request,
                resource: resource
            )

            // Use the placeholder to obtain the local identifier for tracking.
            if let jobID = jobRequest.placeholderForCreatedAssetResourceUploadJob?.localIdentifier {
                trackUploadJob(resource.assetLocalIdentifier, jobID: jobID)
            }
        }
    }
}
```

Job creation must occur within a change block. Each [`PHAssetResource`](/documentation/photos/phassetresource) you upload requires a separate job. The destination [`URLRequest`](/documentation/Foundation/URLRequest) contains your server endpoint, authentication headers, and any metadata needed for upload processing.

The system enforces an inflight job limit. When you exceed that limit, `Photos/PHPhotoLibrary/performChanges(_:)` throws a [`limitExceeded`](/documentation/photos/phphotoserror-swift.struct/limitexceeded) exception. When job creation throws [`limitExceeded`](/documentation/photos/phphotoserror-swift.struct/limitexceeded), acknowledge completed jobs first, then retry creation.

Return `.processing` from the [`processJobs()`](/documentation/photos/phbackgroundresourceuploadjobextension/processjobs\(\)) method to have the system call your extension again once the upload jobs have completed.

While your extension has jobs to process, keep the job queue filled to its limit to ensure efficient processing.

## [Create download-only jobs](/documentation/photokit/uploading-asset-resources-in-the-background#Create-download-only-jobs)

The system automatically downloads asset resources before processing. However, if your workflow requires local access to the resource before submitting a processing job, the system can download the resource locally without uploading it.

Use [`creationRequestForDownloadJob(resource:)`](/documentation/photos/phassetresourceuploadjobchangerequest/creationrequestfordownloadjob\(resource:\)) to create a job that downloads a resource from iCloud without uploading it to a server. Download-only jobs follow the same life cycle as upload jobs, transitioning through [`PHAssetResourceUploadJob.State.registered`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/registered), [`PHAssetResourceUploadJob.State.pending`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/pending), and eventually [`PHAssetResourceUploadJob.State.succeeded`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/succeeded) or [`PHAssetResourceUploadJob.State.failed`](/documentation/photos/phassetresourceuploadjob/state-swift.enum/failed) states.

```
private func createDownloadJobs(for resources: [PHAssetResource]) throws {
    let library = PHPhotoLibrary.shared()

    try library.performChangesAndWait {
        for resource in resources {
            let jobRequest = PHAssetResourceUploadJobChangeRequest.creationRequestForDownloadJob(
                resource: resource
            )

            if let jobID = jobRequest.placeholderForCreatedAssetResourceUploadJob?.localIdentifier {
                trackDownloadJob(resource.assetLocalIdentifier, jobID: jobID)
            }
        }
    }
}
```

When acknowledging completed jobs, check the [`type`](/documentation/photos/phassetresourceuploadjob/type-swift.property) property to distinguish download-only jobs from upload jobs. Download-only jobs have a type of [`PHAssetResourceUploadJob.Type.downloadOnly`](/documentation/photos/phassetresourceuploadjob/type-swift.enum/downloadonly).

## [Handle extension termination](/documentation/photokit/uploading-asset-resources-in-the-background#Handle-extension-termination)

The system calls [`willTerminate()`](/documentation/photos/phbackgroundresourceuploadjobextension/willterminate\(\)) before suspending or terminating your extension. Use this method to stop current work and clean up resources.

The system may call this method at any time, including while the extension processes uploads. Ensure the extension exits the process method promptly after receiving a termination notification.

```
class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension {
    private let isCancelled = Atomic<Bool>(false)

    func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
        // Perform work, checking cancellation periodically.
        if isCancelled.load(ordering: .acquiring) {
            return .processing
        }

        // Return `.completed` if you've processed all items, and
        // `.processing` if there are resources remaining to upload.
        return .completed
    }

    func willTerminate() async {
        // Signal the `processJobs()` method to exit.
        isCancelled.store(true, ordering: .releasing)

        // Perform any necessary clean up.
    }
}
```

Upon receiving a termination notification, cancel any in-progress work such as network requests or database operations. Set cancellation flags that the [`processJobs()`](/documentation/photos/phbackgroundresourceuploadjobextension/processjobs\(\)) method checks periodically to interrupt processing.

## [Support resumable uploads](/documentation/photokit/uploading-asset-resources-in-the-background#Support-resumable-uploads)

The background upload system supports resumable uploads according to the draft [IETF Resumable Uploads for HTTP](https://datatracker.ietf.org/doc/draft-ietf-httpbis-resumable-upload/) protocol. Resumable uploads allow interrupted transfers to continue from the point of interruption, rather than restarting from the beginning. This reduces redundant data transfer for large asset resources uploaded over unreliable network connections.

## [Respond to preflight requests](/documentation/photokit/uploading-asset-resources-in-the-background#Respond-to-preflight-requests)

Before the system begins an upload, it checks whether your server supports the resumable upload protocol. The system sends an HTTP `OPTIONS` request to your upload endpoint to perform this preflight capability check. Your server must respond appropriately to indicate its support.

When your server supports resumable uploads, respond to the `OPTIONS` request with a `200 (OK)` status code and include the `Upload-Limit` header field in the response:

```
OPTIONS /upload HTTP/1.1
Host: api.example.com

HTTP/1.1 200 OK
Upload-Limit: 107374182400
```

The `Upload-Limit` header indicates the maximum upload size your server supports. If your server doesn’t support resumable uploads, respond with a `501 (Not Implemented)` status code.

The system caches this capability check, so your server handles fewer `OPTIONS` requests.

## [Issue an informational response during uploads](/documentation/photokit/uploading-asset-resources-in-the-background#Issue-an-informational-response-during-uploads)

For each upload, your server must also provide in-band feature detection by sending a `104 (Upload Resumption Supported)` informational response while the client uploads the request body.

When your server receives an upload request and has created the upload resource, send the `104` informational response before the final response. Include the `Location` header set to the upload URL:

```
POST /upload HTTP/1.1
Host: api.example.com
Upload-Incomplete: ?0
Content-Length: 52428800

HTTP/1.1 104 Upload Resumption Supported
Location: https://api.example.com/upload/b530ce8ff

HTTP/1.1 201 Created
Location: https://api.example.com/upload/b530ce8ff
Upload-Offset: 52428800
```

The `104` informational response serves as the authoritative signal that the server supports resumable uploads. If an upload is interrupted after the client receives this response, the system automatically resumes the transfer from where it stopped.

## [See Also](/documentation/photokit/uploading-asset-resources-in-the-background#see-also)

### [Related Documentation](/documentation/photokit/uploading-asset-resources-in-the-background#Related-Documentation)

[`protocol PHBackgroundResourceUploadJobExtension`](/documentation/photos/phbackgroundresourceuploadjobextension)Beta

[`class func assetResource(forUploadJob: PHAssetResourceUploadJob) -> PHAssetResource?`](/documentation/photos/phassetresource/assetresource\(foruploadjob:\))

Returns the asset resource associated with the given upload job.

Beta

### [Background resource upload extensions](/documentation/photokit/uploading-asset-resources-in-the-background#Background-resource-upload-extensions)

[`protocol PHBackgroundResourceUploadExtension`](/documentation/photos/phbackgroundresourceuploadextension)Deprecated

[`class PHAssetResourceUploadJob`](/documentation/photos/phassetresourceuploadjob)

An object that represents a request to upload an asset resource.

[`class PHAssetResourceUploadJobChangeRequest`](/documentation/photos/phassetresourceuploadjobchangerequest)

Use within an application’s `com.apple.photos.background-upload` extension to create and change [`PHAssetResourceUploadJob`](/documentation/photos/phassetresourceuploadjob) records.
