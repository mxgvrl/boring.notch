//
//  AIChatProvider.swift
//  boringNotch
//
//  Models and the streaming Anthropic client behind the Ask AI tab.
//

import Defaults
import Foundation

struct AIChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String  // "user" or "assistant"
    var text: String
    var date = Date()
}

enum AIChatEvent {
    case textDelta(String)
    case searching(Bool)
    case done(stopReason: String?)
}

enum AIChatError: Error, Equatable {
    case missingKey
    case unauthorized
    case rateLimited
    case http(Int, String)
    case network(String)

    var message: String {
        switch self {
        case .missingKey: return "Add your Anthropic API key in Settings → Ask AI."
        case .unauthorized: return "The Anthropic API key was rejected."
        case .rateLimited: return "Rate limited. Try again in a moment."
        case .http(let code, let body): return body.isEmpty ? "Request failed (HTTP \(code))." : "HTTP \(code): \(body)"
        case .network(let text): return text
        }
    }
}

protocol AIChatProvider {
    func stream(system: String, messages: [AIChatMessage]) -> AsyncThrowingStream<AIChatEvent, Error>
}

struct AnthropicProvider: AIChatProvider {
    static let model = "claude-haiku-5-5"

    func stream(system: String, messages: [AIChatMessage]) -> AsyncThrowingStream<AIChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = await MainActor.run { Defaults[.anthropicAPIKey] }
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let webSearch = await MainActor.run { Defaults[.aiChatWebSearch] }
                    guard !key.isEmpty else { throw AIChatError.missingKey }

                    var body: [String: Any] = [
                        "model": Self.model,
                        "max_tokens": 2048,
                        "stream": true,
                        "system": system,
                        "output_config": ["effort": "low"],
                        "thinking": ["type": "adaptive"],
                        "messages": messages.map { ["role": $0.role, "content": $0.text] },
                    ]
                    if webSearch {
                        body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 2]]
                    }

                    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue(key, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    request.timeoutInterval = 120

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw Self.map(status: status, body: data)
                    }

                    var hadTextBlock = false
                    var needsSeparator = false
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else { continue }
                        switch type {
                        case "content_block_start":
                            let blockType = (json["content_block"] as? [String: Any])?["type"] as? String
                            if blockType == "text", hadTextBlock { needsSeparator = true }
                            if blockType == "server_tool_use" {
                                continuation.yield(.searching(true))
                            } else if blockType == "web_search_tool_result" {
                                continuation.yield(.searching(false))
                            }
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                hadTextBlock = true
                                if needsSeparator {
                                    needsSeparator = false
                                    continuation.yield(.textDelta("\n\n"))
                                }
                                continuation.yield(.textDelta(text))
                            }
                        case "message_delta":
                            let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String
                            continuation.yield(.done(stopReason: reason))
                        case "error":
                            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                            throw AIChatError.network(message)
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as AIChatError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIChatError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func map(status: Int, body: Data) -> AIChatError {
        switch status {
        case 401: return .unauthorized
        case 429: return .rateLimited
        default:
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(data: body.prefix(200), encoding: .utf8) ?? ""
            return .http(status, message)
        }
    }
}
