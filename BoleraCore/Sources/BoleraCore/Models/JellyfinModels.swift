import Foundation

// MARK: - Authentication

public struct AuthRequest: Encodable {
    public let Username: String
    public let Pw: String

    public init(Username: String, Pw: String) {
        self.Username = Username
        self.Pw = Pw
    }
}

public struct AuthResponse: Decodable {
    public let User: JellyfinUser
    public let AccessToken: String
    public let ServerId: String
}

public struct JellyfinUser: Decodable, Identifiable {
    public let Id: String
    public let Name: String
    public var id: String { Id }
}

// MARK: - Items

public struct ItemsResponse<T: Decodable>: Decodable {
    public let Items: [T]
    public let TotalRecordCount: Int?
    public let StartIndex: Int?
}

public struct BaseItem: Codable, Identifiable, Hashable {
    public let Id: String
    public let Name: String
    public let type: String?
    public let AlbumId: String?
    public let Album: String?
    public let AlbumArtist: String?
    public let AlbumArtists: [NameId]?
    public let ArtistItems: [NameId]?
    public let Artists: [String]?
    public let ParentId: String?
    public let CollectionType: String?
    public let RunTimeTicks: Int64?
    public let IndexNumber: Int?
    public let ParentIndexNumber: Int?
    public let ProductionYear: Int?
    public let UserData: UserData?
    public let ImageTags: [String: String]?
    public let AlbumPrimaryImageTag: String?
    public let BackdropImageTags: [String]?
    public let ChildCount: Int?
    public let SongCount: Int?
    public let AlbumCount: Int?
    public let Overview: String?
    public let Genres: [String]?

    public var id: String { Id }

    public static func == (lhs: BaseItem, rhs: BaseItem) -> Bool { lhs.Id == rhs.Id }
    public func hash(into hasher: inout Hasher) { hasher.combine(Id) }

    /// Light-weight constructor for synthesizing a stub before the server
    /// round-trip completes — lets navigation push immediately while the
    /// destination view fetches its own data.
    public static func stub(id: String, name: String, type: String?) -> BaseItem {
        BaseItem(
            Id: id, Name: name, type: type,
            AlbumId: nil, Album: nil, AlbumArtist: nil,
            AlbumArtists: nil, ArtistItems: nil, Artists: nil,
            ParentId: nil, CollectionType: nil,
            RunTimeTicks: nil, IndexNumber: nil, ParentIndexNumber: nil, ProductionYear: nil,
            UserData: nil, ImageTags: nil, AlbumPrimaryImageTag: nil, BackdropImageTags: nil,
            ChildCount: nil, SongCount: nil, AlbumCount: nil, Overview: nil, Genres: nil
        )
    }

    public init(
        Id: String, Name: String, type: String?,
        AlbumId: String?, Album: String?, AlbumArtist: String?,
        AlbumArtists: [NameId]?, ArtistItems: [NameId]?, Artists: [String]?,
        ParentId: String?, CollectionType: String?,
        RunTimeTicks: Int64?, IndexNumber: Int?, ParentIndexNumber: Int?, ProductionYear: Int?,
        UserData: UserData?, ImageTags: [String: String]?,
        AlbumPrimaryImageTag: String?, BackdropImageTags: [String]?,
        ChildCount: Int?, SongCount: Int?, AlbumCount: Int?,
        Overview: String?, Genres: [String]?
    ) {
        self.Id = Id; self.Name = Name; self.type = type
        self.AlbumId = AlbumId; self.Album = Album; self.AlbumArtist = AlbumArtist
        self.AlbumArtists = AlbumArtists; self.ArtistItems = ArtistItems; self.Artists = Artists
        self.ParentId = ParentId; self.CollectionType = CollectionType
        self.RunTimeTicks = RunTimeTicks; self.IndexNumber = IndexNumber
        self.ParentIndexNumber = ParentIndexNumber; self.ProductionYear = ProductionYear
        self.UserData = UserData; self.ImageTags = ImageTags
        self.AlbumPrimaryImageTag = AlbumPrimaryImageTag; self.BackdropImageTags = BackdropImageTags
        self.ChildCount = ChildCount; self.SongCount = SongCount; self.AlbumCount = AlbumCount
        self.Overview = Overview; self.Genres = Genres
    }

    public var durationSeconds: Double {
        guard let ticks = RunTimeTicks else { return 0 }
        return Double(ticks) / 10_000_000
    }

    public var primaryArtistName: String {
        AlbumArtist ?? AlbumArtists?.first?.Name ?? ArtistItems?.first?.Name ?? Artists?.first ?? ""
    }

    /// Best item ID to request a Primary image for. For an Audio track we
    /// prefer the album cover, because per-track embedded art is rare —
    /// most libraries store one cover per album folder. We use the album
    /// id when EITHER the album image tag was fetched OR the track itself
    /// exposes no Primary image of its own. (Track fetches like
    /// `songs(parentId:)` don't request `AlbumPrimaryImageTag`, so relying
    /// on that tag being present left the mini player's current-track art
    /// blank — it fell through to `Items/{trackId}/Images/Primary`, which
    /// 404s for tracks with no embedded art.) Only when the track genuinely
    /// has its own art do we request the track id. Jellyfin serves
    /// `Items/{albumId}/Images/Primary` fine without a tag.
    public var artworkItemId: String {
        if type == "Audio", let albumId = AlbumId, !albumId.isEmpty,
           AlbumPrimaryImageTag != nil || ImageTags?["Primary"] == nil {
            return albumId
        }
        return Id
    }

    /// Matching image tag for `artworkItemId`. May be nil; the server may still serve
    /// the image without a tag, but caching benefits from supplying one.
    public var artworkTag: String? {
        if type == "Audio", let albumTag = AlbumPrimaryImageTag {
            return albumTag
        }
        return ImageTags?["Primary"]
    }

    public enum CodingKeys: String, CodingKey {
        case Id, Name
        case type = "Type"
        case AlbumId, Album, AlbumArtist, AlbumArtists, ArtistItems, Artists
        case ParentId, CollectionType
        case RunTimeTicks, IndexNumber, ParentIndexNumber, ProductionYear
        case UserData, ImageTags, AlbumPrimaryImageTag, BackdropImageTags
        case ChildCount, SongCount, AlbumCount, Overview, Genres
    }
}

public struct NameId: Codable, Hashable {
    public let Name: String
    public let Id: String
}

public struct UserData: Codable, Hashable {
    public let PlayCount: Int?
    public let IsFavorite: Bool?
    public let Played: Bool?
    public let PlaybackPositionTicks: Int64?
    public let LastPlayedDate: String?
}

// MARK: - Search hints

public struct SearchHintsResponse: Decodable {
    public let SearchHints: [SearchHint]
    public let TotalRecordCount: Int
}

public struct SearchHint: Decodable, Identifiable, Hashable {
    public let ItemId: String?
    public let Id: String?
    public let Name: String
    public let type: String?
    public let Album: String?
    public let AlbumId: String?
    public let AlbumArtist: String?
    public let PrimaryImageTag: String?
    public let RunTimeTicks: Int64?

    public var id: String { ItemId ?? Id ?? UUID().uuidString }

    public enum CodingKeys: String, CodingKey {
        case ItemId, Id, Name
        case type = "Type"
        case Album, AlbumId, AlbumArtist, PrimaryImageTag, RunTimeTicks
    }
}

// MARK: - Playback reporting

public struct PlaybackStartInfo: Encodable {
    public let ItemId: String
    public let PlayMethod: String = "DirectStream"
    public let PlaySessionId: String
    public let PositionTicks: Int64
    public let CanSeek: Bool = true

    public init(ItemId: String, PlaySessionId: String, PositionTicks: Int64) {
        self.ItemId = ItemId
        self.PlaySessionId = PlaySessionId
        self.PositionTicks = PositionTicks
    }
}

public struct PlaybackProgressInfo: Encodable {
    public let ItemId: String
    public let PlaySessionId: String
    public let PositionTicks: Int64
    public let IsPaused: Bool
    public let IsMuted: Bool
    public let PlayMethod: String = "DirectStream"
    public let EventName: String?

    public init(ItemId: String, PlaySessionId: String, PositionTicks: Int64, IsPaused: Bool, IsMuted: Bool, EventName: String?) {
        self.ItemId = ItemId
        self.PlaySessionId = PlaySessionId
        self.PositionTicks = PositionTicks
        self.IsPaused = IsPaused
        self.IsMuted = IsMuted
        self.EventName = EventName
    }
}

public struct PlaybackStopInfo: Encodable {
    public let ItemId: String
    public let PlaySessionId: String
    public let PositionTicks: Int64
    public let PlayMethod: String = "DirectStream"

    public init(ItemId: String, PlaySessionId: String, PositionTicks: Int64) {
        self.ItemId = ItemId
        self.PlaySessionId = PlaySessionId
        self.PositionTicks = PositionTicks
    }
}

