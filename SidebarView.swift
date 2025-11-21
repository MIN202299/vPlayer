import SwiftUI

struct SidebarView: View {
    @ObservedObject var playlistVM: PlaylistViewModel
    @Binding var isImporterPresented: Bool
    var onClose: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with actions
            HStack(spacing: 16) {
                Button(action: { isImporterPresented = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.borderless)
                .help("Add Video")
                
                Spacer()
                
                Button(action: { playlistVM.clearPlaylist() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.borderless)
                .help("Clear Playlist")
            }
            .padding()
            
            Divider()
            
            // List
            List(playlistVM.items, selection: $playlistVM.currentSelection) { item in
                Text(item.title)
                    .tag(item.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(
            ZStack {
                Color.black.opacity(0.2)
                Rectangle().fill(.ultraThinMaterial)
            }
        )
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color.white.opacity(0.15)),
            alignment: .leading
        )
        .frame(width: 250)
        .frame(maxHeight: .infinity)
    }
}
