import SwiftUI

struct SidebarView: View {
    @ObservedObject var playlistVM: PlaylistViewModel
    @Binding var isImporterPresented: Bool
    var onClose: () -> Void
    var onClearPlaylist: () -> Void
    
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
                
                Button(action: { onClearPlaylist() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.borderless)
                .help("Clear Playlist")
            }
            .padding()
            
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
            
            // List
            List(playlistVM.items, selection: $playlistVM.currentSelection) { item in
                Text(item.title)
                    .tag(item.id)
                    .listRowBackground(
                        playlistVM.currentSelection == item.id ?
                        Color(red: 1.0, green: 0.576, blue: 0.0) :
                        nil
                    )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial.opacity(0.7))
                Rectangle().fill(Color.white.opacity(0.02))
            }
        )
        .overlay(
            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.4),
                            Color.white.opacity(0.1)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1),
            alignment: .leading
        )
        .frame(width: 250)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
