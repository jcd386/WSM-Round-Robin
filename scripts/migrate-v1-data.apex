// WSM Round Robin v1 -> v2 data migration (houston-dynamo-prod).
// Idempotent: safe to re-run after mid-migration assignments, it upserts groups by
// developer name, upserts members by unique key, and re-seeds WSM_Last_Assigned__c
// from the v1 pointer so the rotation continues exactly where v1 left off.
// Run AFTER installing WSM Round Robin 2.0, BEFORE cutting caller flows over.

Map<Id, WSM_Round_Robin_Group__c> newGroupByOldId = new Map<Id, WSM_Round_Robin_Group__c>();
Map<String, WSM_Round_Robin_Group__c> existingByDevName = new Map<String, WSM_Round_Robin_Group__c>();
for (WSM_Round_Robin_Group__c g : [SELECT Id, WSM_Developer_Name__c FROM WSM_Round_Robin_Group__c]) {
    existingByDevName.put(g.WSM_Developer_Name__c, g);
}

List<SObject> oldGroups = Database.query(
    'SELECT Id, Name FROM Round_Robin_Group__c ORDER BY Name');
List<WSM_Round_Robin_Group__c> groupsToUpsert = new List<WSM_Round_Robin_Group__c>();
for (SObject og : oldGroups) {
    String oldName = (String) og.get('Name');
    String slug = oldName.toLowerCase().replaceAll('[^a-z0-9]+', '_').replaceAll('^_+|_+$', '');
    WSM_Round_Robin_Group__c g = existingByDevName.get(slug);
    if (g == null) {
        g = new WSM_Round_Robin_Group__c(
            Name = oldName,
            WSM_Developer_Name__c = slug,
            WSM_Algorithm__c = 'Strict Rotation',
            WSM_Capacity_Mode__c = 'None',
            WSM_Period__c = 'Daily',
            WSM_Calibration__c = 'Median',
            WSM_Active__c = true
        );
    }
    groupsToUpsert.add(g);
    newGroupByOldId.put(og.Id, g);
}
upsert groupsToUpsert WSM_Developer_Name__c;
System.debug('Groups migrated: ' + groupsToUpsert.size());

Map<String, WSM_Round_Robin_Member__c> existingMemberByKey = new Map<String, WSM_Round_Robin_Member__c>();
for (WSM_Round_Robin_Member__c m : [SELECT Id, WSM_Unique_Key__c FROM WSM_Round_Robin_Member__c]) {
    existingMemberByKey.put(m.WSM_Unique_Key__c, m);
}

List<SObject> oldMembers = Database.query(
    'SELECT Id, Round_Robin_Group__c, User__c, Active__c, Last_Assigned_Date_Time__c FROM Round_Robin_Group_Member__c');
List<WSM_Round_Robin_Member__c> membersToInsert = new List<WSM_Round_Robin_Member__c>();
List<WSM_Round_Robin_Member__c> membersToUpdate = new List<WSM_Round_Robin_Member__c>();
Integer sortSeq = 10;
for (SObject om : oldMembers) {
    Id oldGroupId = (Id) om.get('Round_Robin_Group__c');
    WSM_Round_Robin_Group__c newGroup = newGroupByOldId.get(oldGroupId);
    if (newGroup == null) { continue; }
    String key = newGroup.Id + '|' + (Id) om.get('User__c');
    WSM_Round_Robin_Member__c existing = existingMemberByKey.get(key);
    if (existing != null) {
        existing.WSM_Last_Assigned__c = (Datetime) om.get('Last_Assigned_Date_Time__c');
        existing.WSM_Active__c = (Boolean) om.get('Active__c');
        membersToUpdate.add(existing);
    } else {
        membersToInsert.add(new WSM_Round_Robin_Member__c(
            WSM_Group__c = newGroup.Id,
            WSM_User__c = (Id) om.get('User__c'),
            WSM_Active__c = (Boolean) om.get('Active__c'),
            WSM_Weight__c = 1,
            WSM_Sort_Order__c = sortSeq,
            WSM_Last_Assigned__c = (Datetime) om.get('Last_Assigned_Date_Time__c')
        ));
        sortSeq += 10;
    }
}
insert membersToInsert;
update membersToUpdate;
System.debug('Members inserted: ' + membersToInsert.size() + ', re-seeded: ' + membersToUpdate.size());
