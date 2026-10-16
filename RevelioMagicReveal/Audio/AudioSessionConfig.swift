import AVFAudio

/// Configuration unique de la session audio, partagée par le micro du souffle, la sortie des retours,
/// le lecteur et l'enregistreur de messages.
///
/// Mode « mesure » : aucun traitement du système (pas d'AGC ni de réduction de bruit), indispensable
/// pour reconnaître le souffle. Tous passent par ici : si l'un changeait la catégorie, les autres la
/// rétabliraient tour à tour et la détection du souffle casserait.
nonisolated enum AudioSessionConfig {
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker]

    /// Applique la catégorie si elle diffère (souvent déjà en place), puis active la session.
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .measurement || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .measurement, options: options)
        }
        try session.setActive(true)
    }

    /// Micro intégré choisi, omnidirectionnel si possible, en mono. Le mode « mesure » refuse la stéréo,
    /// mais le choix du micro est respecté (constaté sur iPhone : sur le micro avant, le bas n'entend plus
    /// rien). Un souffle dirigé vers l'écran arrive sur le micro du haut et passe à côté de celui du bas.
    static func selectMic(_ source: MicSource) {
        let session = AVAudioSession.sharedInstance()
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return }
        try? session.setPreferredInput(builtIn)
        try? session.setPreferredInputNumberOfChannels(1)
        guard let dataSource = builtIn.dataSources?.first(where: { $0.orientation == source.orientation }) else { return }
        if dataSource.supportedPolarPatterns?.contains(.omnidirectional) == true {
            try? dataSource.setPreferredPolarPattern(.omnidirectional)
        }
        try? builtIn.setPreferredDataSource(dataSource)
    }
}
