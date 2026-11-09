import Foundation

// Textos que acompanham o idioma do Mac. A chave é o texto em português;
// idioma sem tradução cai para inglês.

private let language: String = {
    let code = Locale.preferredLanguages.first ?? "en"
    return code.hasPrefix("zh") ? "zh" : String(code.prefix(2))
}()

/// Ordem das colunas: en, es, fr, de, it, ja, ko, zh.
private let columns = ["en", "es", "fr", "de", "it", "ja", "ko", "zh"]

private let table: [String: [String]] = [
    "Trabalho": ["Work", "Trabajo", "Travail", "Arbeit", "Lavoro", "仕事", "업무", "工作"],
    "Pessoal": ["Personal", "Personal", "Personnel", "Privat", "Personale", "個人", "개인", "个人"],
    "Nova estação": ["New station", "Nueva estación", "Nouvelle station", "Neue Station", "Nuova postazione", "新しいステーション", "새 스테이션", "新建工作站"],
    "Nova estação…": ["New station…", "Nueva estación…", "Nouvelle station…", "Neue Station…", "Nuova postazione…", "新しいステーション…", "새 스테이션…", "新建工作站…"],
    "Renomear estação": ["Rename station", "Renombrar estación", "Renommer la station", "Station umbenennen", "Rinomina postazione", "ステーション名を変更", "스테이션 이름 변경", "重命名工作站"],
    "Renomear %@…": ["Rename %@…", "Renombrar %@…", "Renommer %@…", "%@ umbenennen…", "Rinomina %@…", "%@ の名前を変更…", "%@ 이름 변경…", "重命名 %@…"],
    "Apagar %@": ["Delete %@", "Eliminar %@", "Supprimer %@", "%@ löschen", "Elimina %@", "%@ を削除", "%@ 삭제", "删除 %@"],
    "Remover de %@": ["Remove from %@", "Quitar de %@", "Retirer de %@", "Aus %@ entfernen", "Rimuovi da %@", "%@ から削除", "%@에서 제거", "从 %@ 移除"],
    "Fixar em %@": ["Pin to %@", "Fijar en %@", "Épingler à %@", "An %@ anheften", "Fissa in %@", "%@ に固定", "%@에 고정", "固定到 %@"],
    "Mover para": ["Move to", "Mover a", "Déplacer vers", "Verschieben nach", "Sposta in", "移動先", "이동", "移动到"],
    "Mostrar no Finder": ["Show in Finder", "Mostrar en Finder", "Afficher dans le Finder", "Im Finder zeigen", "Mostra nel Finder", "Finder に表示", "Finder에서 보기", "在访达中显示"],
    "Sair": ["Quit", "Salir", "Quitter", "Beenden", "Esci", "終了", "종료", "退出"],
    "Salvar": ["Save", "Guardar", "Enregistrer", "Sichern", "Salva", "保存", "저장", "保存"],
    "Cancelar": ["Cancel", "Cancelar", "Annuler", "Abbrechen", "Annulla", "キャンセル", "취소", "取消"],
    "Estação %@": ["Station %@", "Estación %@", "Station %@", "Station %@", "Postazione %@", "ステーション %@", "스테이션 %@", "工作站 %@"],
    "Casa da Faísca": ["Faísca's home", "Casa de Faísca", "Maison de Faísca", "Faíscas Zuhause", "Casa di Faísca", "Faísca の家", "Faísca의 집", "Faísca 的家"],
]

func tr(_ key: String) -> String {
    if language == "pt" { return key }
    guard let row = table[key] else { return key }
    return row[columns.firstIndex(of: language) ?? 0]
}

func tr(_ key: String, _ arg: String) -> String { tr(key).replacingOccurrences(of: "%@", with: arg) }
