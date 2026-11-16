// 本文件是 Scene 级依赖装配入口；各领域名称是视图依赖边界，不再暴露旧 LibraryStore。

import Observation

enum SearchDomain {}
enum HomeDomain {}
enum ReadingDomain {}
enum OrganizationDomain {}
enum TagDiscoveryDomain {}
enum TaskCenterDomain {}
enum MaintenanceDomain {}

@MainActor
@dynamicMemberLookup
@Observable
final class DomainStore<Domain> {
    @ObservationIgnored let catalog: CatalogStore

    init(catalog: CatalogStore) {
        self.catalog = catalog
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<CatalogStore, Value>) -> Value {
        catalog[keyPath: keyPath]
    }

    subscript<Value>(dynamicMember keyPath: ReferenceWritableKeyPath<CatalogStore, Value>) -> Value {
        get { catalog[keyPath: keyPath] }
        set { catalog[keyPath: keyPath] = newValue }
    }
}

typealias SearchStore = DomainStore<SearchDomain>
typealias HomeStore = DomainStore<HomeDomain>
typealias ReadingStore = DomainStore<ReadingDomain>
typealias OrganizationStore = DomainStore<OrganizationDomain>
typealias TagDiscoveryStore = DomainStore<TagDiscoveryDomain>
typealias TaskCenterStore = DomainStore<TaskCenterDomain>
typealias MaintenanceStore = DomainStore<MaintenanceDomain>

@MainActor
@Observable
final class NyaEHAppModel {
    let changeBus: LibraryChangeBus
    let catalog: CatalogStore
    let search: SearchStore
    let home: HomeStore
    let reading: ReadingStore
    let organization: OrganizationStore
    let tagDiscovery: TagDiscoveryStore
    let taskCenter: TaskCenterStore
    let maintenance: MaintenanceStore

    init(changeBus: LibraryChangeBus = LibraryChangeBus(), catalog: CatalogStore? = nil) {
        self.changeBus = changeBus
        let catalog = catalog ?? CatalogStore.bootstrap(changeBus: changeBus)
        self.catalog = catalog
        search = SearchStore(catalog: catalog)
        home = HomeStore(catalog: catalog)
        reading = ReadingStore(catalog: catalog)
        organization = OrganizationStore(catalog: catalog)
        tagDiscovery = TagDiscoveryStore(catalog: catalog)
        taskCenter = TaskCenterStore(catalog: catalog)
        maintenance = MaintenanceStore(catalog: catalog)
    }
}
