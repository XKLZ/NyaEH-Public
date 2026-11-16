// 本文件定义 LocalHighlightModels 领域模型，是数据库、服务层和 SwiftUI 视图之间传递业务状态的结构。

import CryptoKit
import Foundation

struct LocalHighlightGallerySnapshot: Codable, Equatable, Sendable {
    var app: String
    var revision: String
    var gids: [String]

    init(gids: [String], app: String = "NyaEH") {
        let sortedGIDs = Array(Set(gids)).sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        self.app = app
        revision = Self.revision(for: sortedGIDs)
        self.gids = sortedGIDs
    }

    static func make(from books: [LibraryBook]) -> LocalHighlightGallerySnapshot {
        LocalHighlightGallerySnapshot(
            gids: books.compactMap { book in
                guard book.exist else {
                    return nil
                }
                return LocalHighlightGalleryURLParser.galleryID(from: book.url)
            }
        )
    }

    private static func revision(for gids: [String]) -> String {
        let data = Data(gids.joined(separator: "\n").utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum LocalHighlightGalleryURLParser {
    static func galleryID(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(),
              host == "e-hentai.org" || host == "exhentai.org" else {
            return nil
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 3,
              components[0] == "g",
              components[1].allSatisfy(\.isNumber),
              !components[2].isEmpty else {
            return nil
        }

        return components[1]
    }
}

enum LocalHighlightUserscriptTemplate {
    static func script(port: Int) -> String {
        let normalizedPort = AppPreferences.normalizedLocalHighlightServerPort(port)
        let endpoint = "http://127.0.0.1:\(normalizedPort)/api/highlight/v1/galleries"
        return """
        // ==UserScript==
        // @name         NyaEH Local Gallery Highlight
        // @namespace    https://github.com/gazelee/NyaEH
        // @version      1.0.0
        // @description  Highlight E-Hentai / ExHentai galleries that exist in your local NyaEH library.
        // @match        *://e-hentai.org/*
        // @match        *://exhentai.org/*
        // @grant        GM_addStyle
        // @grant        GM.xmlHttpRequest
        // @connect      127.0.0.1
        // ==/UserScript==

        (function () {
          'use strict';

          const endpoint = '\(endpoint)';
          const highlightGradient = 'linear-gradient(-90deg, #602ce5cc 0, #2ce597cc 20%, #e7bb18cc 40%, #ff7657cc 60%, #45c1eecc 80%, #2ce597cc 100%)';
          let revision = null;
          let gids = new Set();

          GM_addStyle(`
            .nyaeh-local-highlight {
              border-color: #fff !important;
              background-image: ${highlightGradient} !important;
            }
          `);

          function requestJSON(url) {
            return new Promise((resolve, reject) => {
              GM.xmlHttpRequest({
                method: 'GET',
                url,
                timeout: 5000,
                onload: response => {
                  if (response.status < 200 || response.status >= 300) {
                    reject(new Error(`NyaEH highlight request failed: ${response.status}`));
                    return;
                  }
                  try {
                    resolve(JSON.parse(response.responseText));
                  } catch (error) {
                    reject(error);
                  }
                },
                onerror: reject,
                ontimeout: () => reject(new Error('NyaEH highlight request timed out'))
              });
            });
          }

          function applyHighlights() {
            gids.forEach(gid => {
              const posted = document.getElementById(`posted_${gid}`);
              if (posted) {
                posted.classList.add('nyaeh-local-highlight');
              }
            });
          }

          async function refreshHighlights() {
            try {
              const snapshot = await requestJSON(endpoint);
              if (snapshot.revision !== revision) {
                revision = snapshot.revision;
                gids = new Set(snapshot.gids || []);
              }
              applyHighlights();
            } catch (ignored) {
              // Keep the page quiet when NyaEH is closed or the local service is disabled.
            }
          }

          setInterval(refreshHighlights, 10000);
          refreshHighlights();
        })();
        """
    }
}
