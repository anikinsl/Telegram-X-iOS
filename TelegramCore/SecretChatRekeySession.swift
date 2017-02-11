import Foundation
#if os(macOS)
    import PostboxMac
    import MtProtoKitMac
#else
    import Postbox
    import MtProtoKitDynamic
#endif

private let keyUseCountThreshold: Int32 = 100

func secretChatInitiateRekeySessionIfNeeded(modifier: Modifier, peerId: PeerId, state: SecretChatState) -> SecretChatState {
    switch state.embeddedState {
        case let .sequenceBasedLayer(sequenceState):
            if let _ = sequenceState.rekeyState {
                return state
            }
            let tagLocalIndex = modifier.operationLogGetNextEntryLocalIndex(peerId: peerId, tag: OperationLogTags.SecretOutgoing)
            let canonicalIndex = sequenceState.canonicalOutgoingOperationIndex(tagLocalIndex)
            if let key = state.keychain.latestKey(validForSequenceBasedCanonicalIndex: canonicalIndex), key.useCount >= keyUseCountThreshold {
                let sessionId = arc4random64()
                let aBytes = malloc(256)!
                let _ = SecRandomCopyBytes(nil, 256, aBytes.assumingMemoryBound(to: UInt8.self))
                let a = MemoryBuffer(memory: aBytes, capacity: 256, length: 256, freeWhenDone: true)
                
                modifier.operationLogAddEntry(peerId: peerId, tag: OperationLogTags.SecretOutgoing, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: SecretChatOutgoingOperation(contents: .pfsRequestKey(layer: .layer46, actionGloballyUniqueId: arc4random64(), rekeySessionId: sessionId, a: a), mutable: true, delivered: false))
                return state.withUpdatedEmbeddedState(.sequenceBasedLayer(sequenceState.withUpdatedRekeyState(SecretChatRekeySessionState(id: sessionId, data: .requesting))))
            }
        default:
            break
    }
    return state
}

func secretChatAdvanceRekeySessionIfNeeded(modifier: Modifier, peerId: PeerId, state: SecretChatState, action: SecretChatRekeyServiceAction) -> SecretChatState {
    switch state.embeddedState {
        case let .sequenceBasedLayer(sequenceState):
            switch action {
                case let .pfsAbortSession(rekeySessionId):
                    if let rekeySession = sequenceState.rekeyState, rekeySession.id == rekeySessionId {
                        return state.withUpdatedEmbeddedState(.sequenceBasedLayer(sequenceState.withUpdatedRekeyState(nil)))
                    }
                case let .pfsAcceptKey(rekeySessionId, gB, keyFingerprint):
                    if let rekeySession = sequenceState.rekeyState, rekeySession.id == rekeySessionId {
                        switch rekeySession.data {
                            case let .requested(a, config):
                                var gValue: Int32 = config.g.byteSwapped
                                let g = Data(bytes: &gValue, count: 4)
                                let p = config.p.makeData()
                                
                                let aData = a.makeData()
                                
                                var key = MTExp(gB.makeData(), aData, p)!
                                
                                if key.count > 256 {
                                    key.count = 256
                                } else  {
                                    while key.count < 256 {
                                        key.insert(0, at: 0)
                                    }
                                }
                                
                                let keyHash = MTSha1(key)!
                                
                                var keyFingerprint: Int64 = 0
                                keyHash.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
                                    memcpy(&keyFingerprint, bytes.advanced(by: keyHash.count - 8), 8)
                                }
                                
                                modifier.operationLogAddEntry(peerId: peerId, tag: OperationLogTags.SecretOutgoing, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: SecretChatOutgoingOperation(contents: .pfsCommitKey(layer: .layer46, actionGloballyUniqueId: arc4random64(), rekeySessionId: rekeySession.id, keyFingerprint: keyFingerprint), mutable: true, delivered: false))
                                
                                let keyValidityOperationIndex = modifier.operationLogGetNextEntryLocalIndex(peerId: peerId, tag: OperationLogTags.SecretOutgoing)
                                let keyValidityOperationCanonicalIndex = sequenceState.canonicalOutgoingOperationIndex(keyValidityOperationIndex)
                                
                                return state.withUpdatedEmbeddedState(.sequenceBasedLayer(sequenceState.withUpdatedRekeyState(nil))).withUpdatedKeychain(state.keychain.withUpdatedKey(fingerprint: keyFingerprint, { _ in
                                    return SecretChatKey(fingerprint: keyFingerprint, key: MemoryBuffer(data: key), validity: .sequenceBasedIndexRange(fromCanonicalIndex: keyValidityOperationCanonicalIndex), useCount: 0)
                                }))
                            default:
                                assertionFailure()
                                break
                        }
                    }
                case let .pfsCommitKey(rekeySessionId, keyFingerprint):
                    if let rekeySession = sequenceState.rekeyState, rekeySession.id == rekeySessionId {
                        if case let .accepted(key, localKeyFingerprint) = rekeySession.data, keyFingerprint == localKeyFingerprint {
                            let keyValidityOperationIndex = modifier.operationLogGetNextEntryLocalIndex(peerId: peerId, tag: OperationLogTags.SecretOutgoing)
                            let keyValidityOperationCanonicalIndex = sequenceState.canonicalOutgoingOperationIndex(keyValidityOperationIndex)
                            
                            let updatedState = state.withUpdatedEmbeddedState(.sequenceBasedLayer(sequenceState.withUpdatedRekeyState(nil))).withUpdatedKeychain(state.keychain.withUpdatedKey(fingerprint: keyFingerprint, { _ in
                                return SecretChatKey(fingerprint: keyFingerprint, key: key, validity: .sequenceBasedIndexRange(fromCanonicalIndex: keyValidityOperationCanonicalIndex), useCount: 0)
                            }))
                            
                            modifier.operationLogAddEntry(peerId: peerId, tag: OperationLogTags.SecretOutgoing, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: SecretChatOutgoingOperation(contents: .noop(layer: .layer46, actionGloballyUniqueId: arc4random64()), mutable: true, delivered: false))
                            
                            return updatedState
                        } else {
                            assertionFailure()
                        }
                    } else {
                        assertionFailure()
                    }
                case let .pfsRequestKey(rekeySessionId, gA):
                    var acceptSession = true
                    if let rekeySession = sequenceState.rekeyState {
                        switch rekeySession.data {
                            case .requesting, .requested:
                                if rekeySessionId < rekeySession.id {
                                    modifier.operationLogAddEntry(peerId: peerId, tag: OperationLogTags.SecretOutgoing, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: SecretChatOutgoingOperation(contents: .pfsAbortSession(layer: .layer46, actionGloballyUniqueId: arc4random64(), rekeySessionId: rekeySession.id), mutable: true, delivered: false))
                                } else {
                                    acceptSession = false
                                }
                            case .accepting, .accepted:
                                break
                        }
                    }
                    
                    if acceptSession {
                        let sessionId = arc4random64()
                        let bBytes = malloc(256)!
                        let _ = SecRandomCopyBytes(nil, 256, bBytes.assumingMemoryBound(to: UInt8.self))
                        let b = MemoryBuffer(memory: bBytes, capacity: 256, length: 256, freeWhenDone: true)
                        
                        let rekeySession = SecretChatRekeySessionState(id: rekeySessionId, data: .accepting)
                        
                        modifier.operationLogAddEntry(peerId: peerId, tag: OperationLogTags.SecretOutgoing, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: SecretChatOutgoingOperation(contents: .pfsAcceptKey(layer: .layer46, actionGloballyUniqueId: arc4random64(), rekeySessionId: rekeySession.id, gA: gA, b: b), mutable: true, delivered: false))
                        return state.withUpdatedEmbeddedState(.sequenceBasedLayer(sequenceState.withUpdatedRekeyState(rekeySession)))
                    }
            }
        default:
            break
    }
    return state
}