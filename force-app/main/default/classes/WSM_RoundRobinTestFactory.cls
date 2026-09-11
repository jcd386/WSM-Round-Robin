/** Shared test data builders for the Round Robin engine test suite. */
@isTest
public class WSM_RoundRobinTestFactory {

    private static Integer userCounter = 0;

    public static WSM_Round_Robin_Group__c makeGroup(String name, String algorithm) {
        WSM_Round_Robin_Group__c grp = new WSM_Round_Robin_Group__c();
        grp.Name = name;
        grp.WSM_Algorithm__c = algorithm;
        grp.WSM_Active__c = true;
        grp.WSM_Capacity_Mode__c = 'None';
        grp.WSM_Period__c = 'Daily';
        grp.WSM_Calibration__c = 'Median';
        return grp;
    }

    public static WSM_Round_Robin_Group__c insertGroup(String name, String algorithm) {
        WSM_Round_Robin_Group__c grp = makeGroup(name, algorithm);
        insert grp;
        return grp;
    }

    public static WSM_Round_Robin_Member__c makeMember(Id groupId, Id userId) {
        WSM_Round_Robin_Member__c member = new WSM_Round_Robin_Member__c();
        member.WSM_Group__c = groupId;
        member.WSM_User__c = userId;
        member.WSM_Active__c = true;
        member.WSM_Sort_Order__c = 0;
        return member;
    }

    public static WSM_Round_Robin_Member__c insertMember(Id groupId, Id userId) {
        WSM_Round_Robin_Member__c member = makeMember(groupId, userId);
        insert member;
        return member;
    }

    public static List<WSM_Round_Robin_Member__c> insertMembers(Id groupId, List<Id> userIds) {
        List<WSM_Round_Robin_Member__c> members = new List<WSM_Round_Robin_Member__c>();
        for (Integer i = 0; i < userIds.size(); i++) {
            WSM_Round_Robin_Member__c member = makeMember(groupId, userIds[i]);
            member.WSM_Sort_Order__c = i;
            members.add(member);
        }
        insert members;
        return members;
    }

    /**
     * Inserts standalone Users. Wrapped in System.runAs(currentUser) so the User
     * (setup object) DML doesn't collide with the custom-object DML the rest of a test
     * method performs in the same transaction (MIXED_DML_OPERATION).
     */
    public static List<User> insertUsers(Integer count) {
        Id profileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
        Long baseMillis = Datetime.now().getTime();

        List<User> users = new List<User>();
        for (Integer i = 0; i < count; i++) {
            userCounter++;
            String uniqueTag = String.valueOf(baseMillis + userCounter);
            users.add(new User(
                FirstName = 'RR',
                LastName = 'Test' + userCounter,
                Email = 'wsm.rr.test' + userCounter + '@example.invalid',
                Username = 'wsm.rr.test' + uniqueTag + '@example.invalid',
                Alias = 'rrt' + Math.mod(userCounter, 1000),
                TimeZoneSidKey = 'America/Chicago',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                ProfileId = profileId
            ));
        }

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users;
        }
        return users;
    }

    /** A plain, non-admin user with no WSM permission set assigned — for the without-sharing smoke test. */
    public static User insertRestrictedUser() {
        return insertUsers(1)[0];
    }

    // ---------------------------------------------------------------- capacity queries

    public static WSM_Capacity_Query__c makeCapacityQuery(Id groupId, String label, String objectName,
            String role, Integer cap) {
        return new WSM_Capacity_Query__c(
            WSM_Group__c = groupId,
            WSM_Label__c = label,
            WSM_Object__c = objectName,
            WSM_Role__c = role,
            WSM_Cap__c = cap,
            WSM_Active__c = true,
            WSM_Sort_Order__c = 0
        );
    }

    public static WSM_Capacity_Filter__c makeFilter(Id capacityQueryId, Integer filterNumber, String fieldName,
            String operator, String valueSource, String value) {
        return new WSM_Capacity_Filter__c(
            WSM_Capacity_Query__c = capacityQueryId,
            WSM_Filter_Number__c = filterNumber,
            WSM_Field__c = fieldName,
            WSM_Operator__c = operator,
            WSM_Value_Source__c = valueSource,
            WSM_Value__c = value
        );
    }

    /** Inserts a capacity query plus one simple equals filter and returns the parent. */
    public static WSM_Capacity_Query__c insertCapacityQuery(Id groupId, String label, String objectName,
            String role, Integer cap, String ownerField, String fieldName, String operator, String value) {
        WSM_Capacity_Query__c config = makeCapacityQuery(groupId, label, objectName, role, cap);
        config.WSM_Owner_Field__c = ownerField;
        insert config;
        insert makeFilter(config.Id, 1, fieldName, operator, WSM_CapacityQueryBuilder.SRC_LITERAL, value);
        return config;
    }

    /** Synthetic unsaved Id for a capacity query, for the in-memory compiler tests. */
    public static Id fakeCapacityQueryId(Integer seq) {
        return WSM_Capacity_Query__c.SObjectType.getDescribe().getKeyPrefix()
            + String.valueOf(seq).leftPad(12, '0');
    }
}
