import SwiftUI

struct UploadProgressView: View {
    @EnvironmentObject var uploadManager: UploadManager
    
    var body: some View {
        NavigationView {
            VStack {
                if uploadManager.uploadQueue.isEmpty && !uploadManager.isUploading {
                    emptyStateView
                } else {
                    uploadListView
                }
            }
            .navigationTitle(L10n.UploadProgress.title)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if uploadManager.isUploading {
                        Button(L10n.UploadProgress.pause) {
                            uploadManager.pauseUpload()
                        }
                    } else if !uploadManager.uploadQueue.isEmpty {
                        Button(L10n.UploadProgress.resume) {
                            uploadManager.resumeUpload()
                        }
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text(L10n.UploadProgress.emptyTitle)
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text(L10n.UploadProgress.emptyMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if uploadManager.uploadedCount > 0 {
                Text(L10n.UploadProgress.emptySuccess(uploadManager.uploadedCount))
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(.top, 10)
            }
        }
    }
    
    private var uploadListView: some View {
        VStack(spacing: 0) {
            // Overall Progress
            VStack(spacing: 8) {
                HStack {
                    Text(L10n.UploadProgress.overall)
                        .font(.headline)
                    Spacer()
                    Text("\(uploadManager.completedCount)/\(uploadManager.totalCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                ProgressView(value: uploadManager.overallProgress)
                    .progressViewStyle(LinearProgressViewStyle())
                
                HStack {
                    if uploadManager.isUploading {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(L10n.UploadProgress.uploading)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(L10n.UploadProgress.paused)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Text("\(Int(uploadManager.overallProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemBackground))
            
            Divider()
            
            // Upload Items List
            List {
                ForEach(uploadManager.uploadQueue) { item in
                    UploadItemRow(item: item)
                }
            }
            .listStyle(PlainListStyle())
        }
    }
}

struct UploadItemRow: View {
    @ObservedObject var item: UploadItem
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 50, height: 50)
                    .cornerRadius(6)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 50)
                    .cornerRadius(6)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    // File type badges - JPEG
                    if !item.isVideo {
                        Text("JPEG")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(item.resourcesUploaded["jpeg"] == true || item.resourcesUploaded["heic"] == true ? Color.green : Color.blue)
                            .cornerRadius(3)
                    }
                    
                    // RAW badge
                    if item.hasRAW {
                        Text("RAW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(item.resourcesUploaded["raw"] == true ? Color.green : Color.orange)
                            .cornerRadius(3)
                    }
                    
                    if item.isVideo {
                        Text(L10n.UploadProgress.video)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(item.resourcesUploaded["video"] == true ? Color.green : Color.purple)
                            .cornerRadius(3)
                    }
                }
                
                // Upload status text
                HStack(spacing: 4) {
                    Text(item.statusText)
                        .font(.caption)
                        .foregroundColor(item.statusColor)
                    
                    if item.totalResources > 1 && item.status == .uploading {
                        Text(L10n.UploadProgress.files(item.resourcesUploaded.count, item.totalResources))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                if item.status == .uploading {
                    ProgressView(value: item.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                }
            }
            
            Spacer()
            
            // Status Icon
            VStack(spacing: 2) {
                Group {
                    switch item.status {
                    case .pending:
                        Image(systemName: "clock")
                            .foregroundColor(.gray)
                    case .uploading:
                        ProgressView()
                            .scaleEffect(0.8)
                    case .processing:
                        ProgressView()
                            .scaleEffect(0.8)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                
                // File count display
                if item.totalResources > 1 {
                    Text(L10n.UploadProgress.fileCount(item.totalResources))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    UploadProgressView()
        .environmentObject(UploadManager())
}
