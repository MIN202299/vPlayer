import SwiftUI

struct SidebarView: View {
    @ObservedObject var playlistVM: PlaylistViewModel
    @Binding var isImporterPresented: Bool
    var onClose: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with actions
            HStack(spacing: 16) {
                Spacer()
                
                Button(action: { isImporterPresented = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.borderless)
                .help("Add Video")
                
                // Placeholder for future buttons
                // Button(action: {}) { ... }
            }
            .padding()
            .background(.ultraThinMaterial)
            
            Divider()
            
            // List
            List(playlistVM.items, selection: $playlistVM.currentSelection) { item in
                Text(item.title)
                    .tag(item.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(.ultraThinMaterial) // Sidebar background
        .frame(width: 250)
        .frame(maxHeight: .infinity)
    }
}
