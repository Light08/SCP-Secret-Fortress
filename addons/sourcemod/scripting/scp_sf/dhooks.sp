enum ThinkFunctionEnum
{
	ThinkFunction_None,
	ThinkFunction_SentryThink,
	ThinkFunction_RegenThink
}

static Handle AllowedToHealTarget;
static Handle SetWinningTeam;
static Handle RoundRespawn;
static Handle ForceRespawn;
static int ForceRespawnHook[MAXTF2PLAYERS];
static int ThinkData[MAXENTITIES];
static int CalculateSpeedClient;
static ThinkFunctionEnum ThinkFunction;

void DHook_Setup(GameData gamedata)
{
	DHook_CreateDetour(gamedata, "CBaseEntity::PhysicsDispatchThink", DHook_PhysicsDispatchThinkPre, DHook_PhysicsDispatchThinkPost);
	DHook_CreateDetour(gamedata, "CTFPlayer::CanPickupDroppedWeapon", DHook_CanPickupDroppedWeaponPre, _);
	DHook_CreateDetour(gamedata, "CTFPlayer::DropAmmoPack", DHook_DropAmmoPackPre, _);
	DHook_CreateDetour(gamedata, "CBaseEntity::InSameTeam", DHook_InSameTeamPre, _);
	DHook_CreateDetour(gamedata, "CTFGameMovement::ProcessMovement", DHook_ProcessMovementPre, _);
	DHook_CreateDetour(gamedata, "CTFPlayer::TeamFortress_CalculateMaxSpeed", DHook_CalculateMaxSpeedPre, DHook_CalculateMaxSpeedPost);

	AllowedToHealTarget = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Bool, ThisPointer_CBaseEntity);
	if(AllowedToHealTarget)
	{
		if(DHookSetFromConf(AllowedToHealTarget, gamedata, SDKConf_Signature, "CWeaponMedigun::AllowedToHealTarget"))
		{
			DHookAddParam(AllowedToHealTarget, HookParamType_CBaseEntity);
			if(!DHookEnableDetour(AllowedToHealTarget, false, DHook_AllowedToHealTarget))
				LogError("[Gamedata] Failed to detour CWeaponMedigun::AllowedToHealTarget");
		}
		else
		{
			LogError("[Gamedata] Could not find CWeaponMedigun::AllowedToHealTarget");
		}
	}
	else
	{
		LogError("[Gamedata] Could not find CWeaponMedigun::AllowedToHealTarget");
	}

	SetWinningTeam = DHookCreateFromConf(gamedata, "CTeamplayRules::SetWinningTeam");
	if(!SetWinningTeam)
		LogError("[Gamedata] Could not find CTeamplayRules::SetWinningTeam");

	RoundRespawn = DHookCreateFromConf(gamedata, "CTeamplayRoundBasedRules::RoundRespawn");
	if(!RoundRespawn)
		LogError("[Gamedata] Could not find CTFPlayer::RoundRespawn");

	ForceRespawn = DHookCreateFromConf(gamedata, "CBasePlayer::ForceRespawn");
	if(!ForceRespawn)
		LogError("[Gamedata] Could not find CBasePlayer::ForceRespawn");
}

static void DHook_CreateDetour(GameData gamedata, const char[] name, DHookCallback preCallback = INVALID_FUNCTION, DHookCallback postCallback = INVALID_FUNCTION)
{
	Handle detour = DHookCreateFromConf(gamedata, name);
	if(detour)
	{
		if(preCallback!=INVALID_FUNCTION && !DHookEnableDetour(detour, false, preCallback))
			LogError("[Gamedata] Failed to enable pre detour: %s", name);
		
		if(postCallback!=INVALID_FUNCTION && !DHookEnableDetour(detour, true, postCallback))
			LogError("[Gamedata] Failed to enable post detour: %s", name);

		delete detour;
	}
	else
	{
		LogError("[Gamedata] Could not find %s", name);
	}
}

void DHook_HookClient(int client)
{
	if(ForceRespawn)
		ForceRespawnHook[client] = DHookEntity(ForceRespawn, false, client, _, DHook_ForceRespawn);
}

void DHook_UnhookClient(int client)
{
	DHookRemoveHookID(ForceRespawnHook[client]);
}

void DHook_MapStart()
{
	if(SetWinningTeam)
		DHookGamerules(SetWinningTeam, false, _, DHook_SetWinningTeam);

	if(RoundRespawn)
		DHookGamerules(RoundRespawn, false, _, DHook_RoundRespawn);
}

public MRESReturn DHook_RoundRespawn()
{
	if(Enabled || !Ready)
		return;

	DClassEscaped = 0;
	DClassMax = 1;
	SciEscaped = 0;
	SciMax = 0;
	SCPKilled = 0;
	SCPMax = 0;

	int total;
	int[] clients = new int[MaxClients];
	for(int client=1; client<=MaxClients; client++)
	{
		Client[client].NextSongAt = 0.0;
		Client[client].AloneIn = FAR_FUTURE;
		if(!IsValidClient(client) || GetClientTeam(client)<=view_as<int>(TFTeam_Spectator))
		{
			Client[client].Class = Class_Spec;
			continue;
		}

		if(TestForceClass[client] <= Class_Spec)
		{
			clients[total++] = client;
			continue;
		}

		Client[client].Class = TestForceClass[client];
		TestForceClass[client] = Class_Spec;
		switch(Client[client].Class)
		{
			case Class_DBoi:
			{
				DClassMax++;
			}
			case Class_Scientist:
			{
				SciMax++;
			}
			default:
			{
				if(IsSCP(client))
					SCPMax++;
			}
		}
		AssignTeam(client);
	}

	if(!total)
		return;

	int client = clients[GetRandomInt(0, total-1)];
	switch(Gamemode)
	{
		case Gamemode_Nut:
			Client[client].Class = Class_173;

		case Gamemode_Steals:
			Client[client].Class = total>1 ? Class_Stealer : Class_DBoi;

		default:
			Client[client].Class = Class_DBoi;
	}
	AssignTeam(client);

	float time = GetEngineTime()+5.0;
	ArrayList list = GetSCPList();
	for(int i; i<total; i++)
	{
		if(clients[i] == client)
			continue;

		if(Client[clients[i]].Setup(view_as<TFTeam>(GetRandomInt(2, 3)), IsFakeClient(clients[i]), list, DClassMax, SciMax, SCPMax) != Class_DBoi)
			Client[clients[i]].InvisFor = time;

		AssignTeam(clients[i]);
	}
	delete list;

	Enabled = true;
}

public MRESReturn DHook_AllowedToHealTarget(int weapon, Handle returnVal, Handle params)
{
	if(weapon==-1 || DHookIsNullParam(params, 1))
		return MRES_Ignored;

	//int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	int target = DHookGetParam(params, 1);
	if(!IsValidClient(target) || !IsPlayerAlive(target))
		return MRES_Ignored;

	DHookSetReturn(returnVal, false);
	return MRES_ChangedOverride;
}

public MRESReturn DHook_ForceRespawn(int client)
{
	if(Enabled && Client[client].Class==Class_Spec && !CvarSpecGhost.BoolValue)
		return MRES_Supercede;

	if(view_as<TFClassType>(GetEntProp(client, Prop_Send, "m_iDesiredPlayerClass")) == TFClass_Unknown)
		SetEntProp(client, Prop_Send, "m_iDesiredPlayerClass", ClassClass[Client[client].Class]);

	return MRES_Ignored;
}

public MRESReturn DHook_SetWinningTeam(Handle params)
{
	if(Enabled)
		return MRES_Supercede;

	DHookSetParam(params, 4, false);
	return MRES_ChangedOverride;
}

public MRESReturn DHook_PhysicsDispatchThinkPre(int entity, Handle params)
{
	//This detour calls everytime an entity was about to call a think function, useful as it only requires 1 gamedata
	if(Enabled)
	{
		static char classname[256];
		if(GetEntityClassname(entity, classname, sizeof(classname)))
		{
			if(StrEqual(classname, "obj_sentrygun"))	// CObjectSentrygun::SentryThink
			{
				ThinkFunction = ThinkFunction_SentryThink;

				//Sentry can only target one team, move all friendly to sentry team, move everyone else to enemy team.
				//CTeam class is used to collect players, so m_iTeamNum change wont be enough to fix it.
				TFTeam team = TF2_GetTeam(entity);
				Address address = SDKCall_GetGlobalTeam(team==TFTeam_Red ? TFTeam_Blue : TFTeam_Red);

				if(address != Address_Null)
				{
					for(int client=1; client<=MaxClients; client++)
					{
						if(!IsValidClient(client) || IsSpec(client))
							continue;

						if(IsSCP(client))
						{
							SDKCall_AddPlayer(address, client);
						}
						else
						{
							SDKCall_RemovePlayer(address, client);
						}
					}
				}

				int building = MaxClients+1;
				while((building=FindEntityByClassname(building, "obj_*")) > MaxClients)
				{
					ThinkData[building] = GetEntProp(building, Prop_Send, "m_iTeamNum");
					if(!GetEntProp(building, Prop_Send, "m_bPlacing"))
						SDKCall_ChangeTeam(building, team);
				}

				//eyeball_boss uses InSameTeam check but obj_sentrygun owner is itself
				SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", GetEntPropEnt(entity, Prop_Send, "m_hBuilder"));
				return MRES_Ignored;
			}

			if(StrEqual(classname, "player"))
			{
				if(IsPlayerAlive(entity) && SDKCall_GetNextThink(entity, "RegenThink")==-1.0)	// CTFPlayer::RegenThink
				{
					if(Client[entity].Class == Class_096)
					{
						ThinkFunction = ThinkFunction_RegenThink;
						TF2_SetPlayerClass(entity, TFClass_Medic);
						return MRES_Ignored;
					}
					else if(TF2_GetPlayerClass(entity) == TFClass_Medic)
					{
						ThinkFunction = ThinkFunction_RegenThink;
						TF2_SetPlayerClass(entity, TFClass_Unknown);
						return MRES_Ignored;
					}
				}
			}
		}
	}
	ThinkFunction = ThinkFunction_None;
	return MRES_Ignored;
}

public MRESReturn DHook_PhysicsDispatchThinkPost(int entity, Handle params)
{
	switch(ThinkFunction)
	{
		case ThinkFunction_SentryThink:
		{
			TFTeam team = TF2_GetTeam(entity)==TFTeam_Red ? TFTeam_Blue : TFTeam_Red;
			Address address = SDKCall_GetGlobalTeam(team);

			for(int client=1; client<=MaxClients; client++)
			{
				if(!IsValidClient(client) || IsSpec(client))
					continue;

				if(IsSCP(client))
				{
					SDKCall_RemovePlayer(address, client);
				}
				else if(Client[client].TeamTF() == team)
				{
					SDKCall_AddPlayer(address, client);
				}
			}

			int building = MaxClients+1;
			while((building=FindEntityByClassname(building, "obj_*")) > MaxClients)
			{
				if(!GetEntProp(building, Prop_Send, "m_bPlacing"))
					SDKCall_ChangeTeam(building, ThinkData[building]);
			}

			SetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity", entity);
		}
		case ThinkFunction_RegenThink:
		{
			if(Client[entity].Class == Class_096)	// TODO: When I'm not lazy
			{
				//TF2_SetPlayerClass(entity, view_as<TFClassType>(ClassClass[Class_096]));
				TF2_SetPlayerClass(entity, TFClass_DemoMan);
			}
			else if(TF2_GetPlayerClass(entity) == TFClass_Unknown)
			{
				TF2_SetPlayerClass(entity, TFClass_Medic);
			}
		}
	}

	ThinkFunction = ThinkFunction_None;
	return MRES_Ignored;
}

public MRESReturn DHook_CanPickupDroppedWeaponPre(int client, Handle returnVal, Handle params)
{
	if(!IsSpec(client) && !IsSCP(client) && !Client[client].Disarmer)
		PickupWeapon(client, DHookGetParam(params, 1));

	DHookSetReturn(returnVal, false);
	return MRES_Supercede;
}

public MRESReturn DHook_DropAmmoPackPre(int client, Handle params)
{
	//Ignore feign death
	if(!DHookGetParam(params, 2) && !IsSpec(client) && !IsSCP(client))
		DropAllWeapons(client);

	//Prevent TF2 dropping anything else
	return MRES_Supercede;
}

public MRESReturn DHook_InSameTeamPre(int entity, Handle returnVal, Handle params)
{
	bool result;
	if(!DHookIsNullParam(params, 1))
	{
		int ent1 = GetOwnerLoop(entity);
		int ent2 = GetOwnerLoop(DHookGetParam(params, 1));
		if(ent1 == ent2)
		{
			result = true;
		}
		else if(IsValidClient(ent1) && IsValidClient(ent2))
		{
			result = IsFriendly(Client[ent1].Class, Client[ent2].Class);
		}
	}

	DHookSetReturn(returnVal, result);
	return MRES_Supercede;
}

public MRESReturn DHook_ProcessMovementPre(Handle params)
{
	if(!Enabled)
		return MRES_Ignored;

	DHookSetParamObjectPtrVar(params, 2, 60, ObjectValueType_Float, MAXTF2SPEED);
	return MRES_ChangedHandled;
}

public MRESReturn DHook_CalculateMaxSpeedPre(Address address, Handle returnVal, Handle params)
{
	CalculateSpeedClient = SDKCall_GetBaseEntity(address);
}

public MRESReturn DHook_CalculateMaxSpeedPost(Address address, Handle returnVal, Handle params)
{
	if(!Enabled || !IsClientInGame(CalculateSpeedClient) || !IsPlayerAlive(CalculateSpeedClient))
		return MRES_Ignored;

	float speed = 1.0;
	if(Client[CalculateSpeedClient].InvisFor != FAR_FUTURE)
	{
		if(TF2_IsPlayerInCondition(CalculateSpeedClient, TFCond_Dazed))
			return MRES_Ignored;

		switch(Client[CalculateSpeedClient].Class)
		{
			case Class_Spec:
			{
				speed = 400.0;
			}
			case Class_DBoi, Class_Scientist:
			{
				if(Gamemode == Gamemode_Steals)
				{
					speed = Client[CalculateSpeedClient].Sprinting ? 360.0 : 270.0;
				}
				else
				{
					speed = Client[CalculateSpeedClient].Disarmer ? 230.0 : Client[CalculateSpeedClient].Sprinting ? 310.0 : 260.0;
				}
			}
			case Class_Chaos, Class_MTFE:
			{
				speed = (Client[CalculateSpeedClient].Sprinting && !Client[CalculateSpeedClient].Disarmer) ? 270.0 : 230.0;
			}
			case Class_MTF3:
			{
				speed = Client[CalculateSpeedClient].Disarmer ? 230.0 : Client[CalculateSpeedClient].Sprinting ? 280.0 : 240.0;
			}
			case Class_Guard, Class_MTF, Class_MTF2, Class_MTFS:
			{
				speed = Client[CalculateSpeedClient].Disarmer ? 230.0 : Client[CalculateSpeedClient].Sprinting ? 290.0 : 250.0;
			}
			case Class_049:
			{
				speed = 250.0;
			}
			case Class_0492, Class_3008:
			{
				speed = 270.0;
			}
			case Class_076:
			{
				switch(Client[CalculateSpeedClient].Radio)
				{
					case 0:
						speed = 240.0;

					case 1:
						speed = 245.0;

					case 2:
						speed = 250.0;

					case 3:
						speed = 255.0;

					default:
						speed = 275.0;
				}
			}
			case Class_096:
			{
				switch(Client[CalculateSpeedClient].Radio)
				{
					case 1:
					{
						speed = 230.0;
					}
					case 2:
					{
						speed = 520.0;
					}
					default:
					{
						speed = 230.0;
					}
				}
			}
			case Class_106:
			{
				speed = 240.0;
			}
			case Class_173:
			{
				switch(Client[CalculateSpeedClient].Radio)
				{
					case 0:
					{
						speed = 420.0;
					}
					case 2:
					{
						speed = 3000.0;
					}
				}
			}
			case Class_1732:
			{
				switch(Client[CalculateSpeedClient].Radio)
				{
					case 0:
					{
						speed = 450.0;
					}
					case 2:
					{
						speed = 2600.0;
					}
				}
			}
			case Class_939, Class_9392:
			{
				speed = 300.0-(GetClientHealth(CalculateSpeedClient)/55.0);
			}
			case Class_Stealer:
			{
				switch(Client[CalculateSpeedClient].Radio)
				{
					case 1:
					{
						speed = 400.0;
					}
					case 2:
					{
						speed = 500.0;
					}
					default:
					{
						speed = 350.0+((SciEscaped/(SciMax+DClassMax)*50.0));
					}
				}
			}
		}
	}

	DHookSetReturn(returnVal, speed);
	return MRES_Override;
}