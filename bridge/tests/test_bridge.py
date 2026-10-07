import contextlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'sidea_bridge.py')
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


def account(name='Personal', **extra):
    return dict(id=str(uuid.uuid4()), name=name, email=name.lower()+'@example.com', ready=True, allowAuto=True, **extra)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def test_corrupt_config_is_not_treated_as_empty(self):
        path = self.root / 'config.json'; path.write_text('{broken')
        with self.assertRaises(json.JSONDecodeError): bridge.read_json(path, {})
    def test_rejects_path_traversal(self):
        with self.assertRaises(ValueError): bridge.account_by_id({'accounts': []}, '../../secret')
        with self.assertRaises(ValueError): bridge.prepare_profile(self.root, '../../secret')
    def test_strips_all_credential_and_provider_overrides(self):
        with patch.dict(os.environ, {'ANTHROPIC_API_KEY': 'secret', 'CLAUDE_CODE_OAUTH_TOKEN': 'secret', 'CLAUDECODE':'1', 'CLAUDE_CODE_USE_BEDROCK':'1', 'AWS_PROFILE':'prod', 'CLAUDE_CONFIG_DIR':'wrong'}):
            env = bridge.clean_environment(self.root)
        self.assertEqual(env['CLAUDE_CONFIG_DIR'], str(self.root))
        for key in ('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDECODE', 'AWS_PROFILE', 'CLAUDE_CODE_USE_BEDROCK'):
            self.assertNotIn(key, env)
    def test_profile_keychain_service_matches_cli_naming(self):
        # Observed in the Keychain for this real profile path with Claude Code 2.1.292.
        root=Path('/Users/arne/Library/Application Support/SideA')
        self.assertEqual(bridge.profile_service(root,'cf1157b7-6e79-4726-949f-4f7a4b92706a'),'Claude Code-credentials-16898129')
    def vault_patches(self, home, vault, owners):
        return [patch.object(Path,'home',return_value=home),
                patch.object(bridge,'read_secret',side_effect=lambda s: json.loads(json.dumps(vault.get(s)))),
                patch.object(bridge,'token_email',side_effect=lambda root,blob: owners.get(((blob or {}).get('claudeAiOauth') or {}).get('accessToken'),''))]
    def setup_pair(self):
        home=self.root/'home'; home.mkdir()
        a,b=account('Alpha'),account('Beta')
        for item in (a,b): bridge.prepare_profile(self.root,item['id'])
        login=lambda token,expires=3600:{'claudeAiOauth':{'accessToken':token,'refreshToken':'r-'+token,'expiresAt':(time.time()+expires)*1000}}
        return home,a,b,login
    def selector(self):
        return (self.root/'runtime/claude-selector').read_text().strip()
    def test_use_points_new_commands_at_the_accounts_own_login(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email'],'beta':b['email']}): stack.enter_context(item)
            self.assertEqual(bridge.global_account(config,self.root),a)
            bridge.activate(self.root,config,b)
            self.assertEqual(self.selector(),str(bridge.profile_dir(self.root,b['id'])))
            self.assertEqual(bridge.global_account(config,self.root),b)
            bridge.activate(self.root,config,a)
            self.assertEqual(self.selector(),'')
        self.assertFalse((home/'.claude.json').exists())
    def test_a_failed_identity_lookup_keeps_the_chosen_account(self):
        # Review: a profile lookup failing after token rotation reset the selection to the Mac login.
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email'],'beta':b['email']}): stack.enter_context(item)
            bridge.activate(self.root,config,b)
        vault[bridge.profile_service(self.root,b['id'])]=login('beta-rotated')
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{'alpha':a['email']}): stack.enter_context(item)
            self.assertEqual(bridge.repair_selection(self.root,config)['id'],b['id'])
        self.assertEqual(self.selector(),str(bridge.profile_dir(self.root,b['id'])))
    def test_selection_follows_the_mac_login_when_it_changes(self):
        # Alpha (the Mac login) is selected; then the Mac signs in as Beta, whose profile slot is a stale copy.
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta-old')}
        owners={'alpha':a['email'],'beta-old':b['email'],'beta-new':b['email']}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            bridge.activate(self.root,config,b)
            vault[bridge.GLOBAL_SERVICE]=login('beta-new')
            # Beta's login now lives in the Mac item, so the old profile selection must not be used.
            self.assertEqual(bridge.repair_selection(self.root,config),b)
            self.assertEqual(self.selector(),'')
    def test_slots_holding_another_accounts_login_are_refused_everywhere(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('alpha-copy')}
        owners={'alpha':a['email'],'alpha-copy':a['email']}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json'))
            run=stack.enter_context(patch.object(bridge.subprocess,'run'))
            for action in (lambda: bridge.activate(self.root,config,b), lambda: bridge.claude_usage(self.root,config,b),
                           lambda: bridge.prime(self.root,config,b)):
                with self.assertRaisesRegex(ValueError,'Sign in to Beta'): action()
            post.assert_not_called(); run.assert_not_called()
        self.assertFalse((self.root/'runtime/claude-selector').exists())
    def test_unverified_login_is_never_used_and_no_mac_login_means_profile_slots(self):
        # Review: an unknown owner (profile lookup failing) was accepted as the account's,
        # and with no Mac login an email-less account was sent to the empty default item.
        home,a,b,login=self.setup_pair()
        vault={bridge.profile_service(self.root,b['id']):login('mystery')}
        config={'accounts':[a,b]}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,{}): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json'))
            for action in (lambda: bridge.activate(self.root,config,b), lambda: bridge.claude_usage(self.root,config,b)):
                with self.assertRaisesRegex(ValueError,"confirm"): action()
            post.assert_not_called()
            self.assertEqual(bridge.home_service(self.root,dict(b,email='')),bridge.profile_service(self.root,b['id']))
    def test_usage_reads_without_refreshing_or_writing_a_login(self):
        home,a,b,login=self.setup_pair()
        vault={bridge.GLOBAL_SERVICE:login('alpha'), bridge.profile_service(self.root,b['id']):login('beta',expires=-5000)}
        owners={'alpha':a['email'],'beta':b['email']}
        config={'accounts':[a,b]}
        usage={'five_hour':{'utilization':40,'resets_at':'2026-10-06T20:00:00Z'},'seven_day':{'utilization':10,'resets_at':None}}
        with contextlib.ExitStack() as stack:
            for item in self.vault_patches(home,vault,owners): stack.enter_context(item)
            post=stack.enter_context(patch.object(bridge,'post_json',return_value=usage))
            result=bridge.claude_usage(self.root,config,a)
            self.assertEqual([w['percent'] for w in result['windows']],[40.0,10.0])
            # An expired login has not been used since it expired; it is never refreshed.
            with self.assertRaisesRegex(ValueError,'idle'): bridge.claude_usage(self.root,config,b)
            self.assertEqual(post.call_count,1)
            # Review: a 401 returned empty windows, wiping the last reading with no backoff.
            post.side_effect=bridge.urllib.error.HTTPError(bridge.USAGE_URL,401,'',{},None)
            with self.assertRaisesRegex(ValueError,'Sign in to Alpha'): bridge.claude_usage(self.root,config,a)
        self.assertFalse(hasattr(bridge,'write_secret'))
    def test_model_scoped_weekly_limits_become_their_own_windows(self):
        data={'limits':[{'kind':'session','percent':74,'resets_at':'2026-10-07T05:39:59Z'},
                        {'kind':'weekly_all','percent':20,'resets_at':'2026-10-13T22:59:59Z'},
                        {'kind':'weekly_scoped','percent':35,'resets_at':'2026-10-13T22:59:59Z',
                         'scope':{'model':{'id':None,'display_name':'Fable'},'surface':None}},
                        {'kind':'weekly_scoped','percent':50,'scope':{'model':{'display_name':'Opus'}}},
                        {'kind':'weekly_scoped','percent':9,'scope':None}]}
        windows=bridge.model_windows(data,{'Weekly Opus'})
        self.assertEqual(windows,[{'id':'seven_day_model:fable','label':'Weekly Fable','percent':35.0,
                                   'resetsAt':bridge.epoch('2026-10-13T22:59:59Z')}])
        self.assertEqual(bridge.model_windows({'limits':None},set()),[])

    def test_shell_switch_survives_path_aliases_and_upgrades_the_old_function(self):
        home=self.root/'home'; home.mkdir(); rc=home/'.zshrc'
        fake=self.root/'bin'; fake.mkdir(); (fake/'claude').write_text('#!/bin/sh\necho "${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}|$*"\n'); (fake/'claude').chmod(0o755)
        # The installer's alias points at a path, which skipped the old `claude` function.
        mine=f"alias claude={fake}/claude\n"
        # Review: a dotfiles-managed (symlinked) .zshrc was replaced by a plain file.
        dotfiles=self.root/'dotfiles'; dotfiles.mkdir()
        (dotfiles/'zshrc').write_text(mine+"\n"+bridge.SHELL_MARK+"\nfunction claude { command claude \"$@\"; }\n")
        rc.symlink_to(dotfiles/'zshrc')
        with patch.object(Path,'home',return_value=home):
            self.assertTrue(bridge.shell_installed(self.root))
            bridge.set_shell(self.root,True)
            self.assertTrue(rc.is_symlink())
            self.assertEqual(rc.read_text().count(bridge.SHELL_MARK),1)
            self.assertNotIn('function claude',rc.read_text())
            selector=self.root/'runtime/claude-selector'; selector.parent.mkdir(parents=True,exist_ok=True)
            run=lambda: subprocess.run(['zsh','-fc',f"source {rc}; (( ${{preexec_functions[(I)_side_a_select]}} )) || exit 3; _side_a_select; eval 'claude --version'"],
                                       capture_output=True,text=True).stdout.strip()
            selector.write_text('/profiles/x\n')
            self.assertEqual(run(),'/profiles/x|--version')
            # Review: `source ~/.zshrc && claude` ran before preexec existed and used the Mac login.
            self.assertEqual(subprocess.run(['zsh','-fc',f"source {rc} && {fake}/claude --version"],capture_output=True,text=True).stdout.strip(),'/profiles/x|--version')
            # Review: the Mac login must be selected explicitly (empty), or an exported
            # CLAUDE_CONFIG_DIR would pick that directory's login instead.
            selector.write_text('\n')
            self.assertEqual(run(),'|--version')
            # Review: shells opened before switching was turned off must stop following Side A.
            bridge.set_shell(self.root,False)
            self.assertFalse(selector.exists())
            self.assertEqual(subprocess.run(['zsh','-fc',f"PATH={fake}:$PATH; {bridge.shell_snippet(self.root).splitlines()[1]}; _side_a_select; claude --version"],
                                            capture_output=True,text=True).stdout.strip(),'unset|--version')
        self.assertEqual(rc.read_text(),mine)
    def test_limit_hook_is_silent_rate_limit_only_and_removable(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        mine={'matcher':'rate_limit','hooks':[{'type':'command','command':'notify-me'}]}
        bridge.atomic_json(home/'.claude/settings.json',{'model':'opus','hooks':{'StopFailure':[mine]}})
        with patch.object(Path,'home',return_value=home):
            bridge.set_limit_hook(self.root,True); bridge.set_limit_hook(self.root,True)
            added=bridge.read_json(home/'.claude/settings.json')['hooks']['StopFailure']
            self.assertEqual(len(added),2)
            self.assertEqual(added[1]['matcher'],'rate_limit')
            subprocess.run(added[1]['hooks'][0]['command'],shell=True,check=True)
            self.assertTrue(bridge.limit_marker(self.root).exists())
            bridge.set_limit_hook(self.root,False)
            self.assertEqual(bridge.read_json(home/'.claude/settings.json'),{'model':'opus','hooks':{'StopFailure':[mine]}})
    def test_fable_maps_to_opus_only_while_side_a_asks_and_keeps_the_users_own_value(self):
        fake=self.root/'bin'; fake.mkdir(); (fake/'claude').write_text('#!/bin/sh\necho "${ANTHROPIC_DEFAULT_FABLE_MODEL-unset}"\n'); (fake/'claude').chmod(0o755)
        line=bridge.shell_snippet(self.root).splitlines()[1]
        run=lambda before='': subprocess.run(['zsh','-fc',f"PATH={fake}:$PATH; {before} {line}; _side_a_select; claude"],
                                             capture_output=True,text=True).stdout.strip()
        self.assertEqual(run(),'unset')
        bridge.set_fable_fallback(self.root,True)
        self.assertEqual(run(),bridge.FABLE_FALLBACK_MODEL)
        # Turned off again: a shell that had the remap drops it, but a value the user exported stays.
        bridge.set_fable_fallback(self.root,False)
        self.assertEqual(run('export ANTHROPIC_DEFAULT_FABLE_MODEL=mine;'),'mine')
        self.assertEqual(subprocess.run(['zsh','-fc',f"PATH={fake}:$PATH; {line}; _side_a_select; rm {bridge.fable_model_path(self.root)}; _side_a_select; claude"],
                                        capture_output=True,text=True).stdout.strip(),'unset')
    def test_opus_fallback_never_overwrites_or_removes_the_users_own_value(self):
        home=self.root/'home'; (home/'.claude').mkdir(parents=True)
        settings=home/'.claude/settings.json'
        bridge.atomic_json(settings,{'model':'opus'})
        with patch.object(Path,'home',return_value=home):
            bridge.set_opus_fallback(True)
            self.assertEqual(bridge.read_json(settings),{'model':'opus','fallbackModel':['opus']})
            bridge.set_opus_fallback(False)
            self.assertEqual(bridge.read_json(settings),{'model':'opus'})
            bridge.atomic_json(settings,{'fallbackModel':['sonnet']})
            bridge.set_opus_fallback(True); bridge.set_opus_fallback(False)
            self.assertEqual(bridge.read_json(settings),{'fallbackModel':['sonnet']})
            self.assertTrue(bridge.opus_fallback_installed())
    def test_sessions_report_model_and_account_from_profile_environment(self):
        home=self.root/'home'; sessions=home/'.claude/sessions'; sessions.mkdir(parents=True)
        project=home/'.claude/projects/-x'; project.mkdir(parents=True)
        a={'id':str(uuid.uuid4()),'name':'A','email':'a@x'}; b={'id':str(uuid.uuid4()),'name':'B','email':'b@x'}
        for pid,sid in ((101,'s1'),(102,'s2'),(103,'s3')):
            bridge.atomic_json(sessions/f'{pid}.json',{'pid':pid,'sessionId':sid,'cwd':'/w','name':f'n{pid}','status':'busy'})
        (project/'s1.jsonl').write_text(json.dumps({'type':'assistant','message':{'model':'claude-fable-5-1'}})+'\n'
                                        +json.dumps({'type':'assistant','message':{'model':'<synthetic>'}})+'\n')
        envs={101:f"claude CLAUDE_SECURESTORAGE_CONFIG_DIR={self.root}/my dir/profiles/{b['id']} TERM=x",102:'claude TERM=x'}
        def ps(command,**_):
            pid=int(command[-1]); return subprocess.CompletedProcess(command,0 if pid in envs else 1,envs.get(pid,''),'')
        with patch.object(Path,'home',return_value=home), patch.object(bridge.subprocess,'run',side_effect=ps), \
             patch.object(bridge,'mac_email',return_value='a@x'):
            result=bridge.live_sessions(self.root,{'accounts':[a,b]})
        self.assertEqual(result,[{'pid':101,'name':'n101','status':'busy','model':'claude-fable-5-1','accountID':b['id']},
                                 {'pid':102,'name':'n102','status':'busy','model':None,'accountID':a['id']}])
    def test_sessions_are_found_by_title_or_lone_folder_and_never_guessed(self):
        terms=[{'id':'T1','cwd':'/a','title':'Fix login'},{'id':'T2','cwd':'/a','title':'other'},{'id':'T3','cwd':'/b','title':'zsh'}]
        a1={'pid':1,'sessionId':'s1','cwd':'/a','name':'a-1'}; a2={'pid':2,'sessionId':'s2','cwd':'/a','name':'a-2'}
        b1={'pid':3,'sessionId':'s3','cwd':'/b','name':'b-1'}
        titles={'s1':{'a-1','Fix login'},'s2':{'a-2'},'s3':{'b-1'}}
        with patch.object(bridge,'session_titles',side_effect=lambda s: titles[s['sessionId']]):
            self.assertEqual(bridge.session_terminal(a1,[a1,a2,b1],terms)['id'],'T1')
            self.assertEqual(bridge.session_terminal(b1,[a1,a2,b1],terms)['id'],'T3')
            # Two tabs in one folder and no title match: refuse rather than type into the wrong one.
            with self.assertRaisesRegex(ValueError,'Ghostty tab'): bridge.session_terminal(a2,[a1,a2,b1],terms)
    def test_resume_keeps_the_sessions_own_flags_and_replaces_conversation_and_model(self):
        args='claude --dangerously-skip-permissions --resume old -c --model opus --permission-mode plan -n x --add-dir /tmp'
        ps=subprocess.CompletedProcess([],0,args+'\n','')
        with patch.object(bridge.subprocess,'run',return_value=ps):
            self.assertEqual(bridge.resume_command(1,'S','fable'),
                ['claude','--resume','S','--dangerously-skip-permissions','--permission-mode','plan','--add-dir','/tmp','--model','fable'])
    def test_report_counts_each_response_once_per_day_and_project(self):
        folder=Path(self.temp.name)/'home/.claude/projects/p'; folder.mkdir(parents=True)
        line=lambda mid,ts,out:json.dumps({'timestamp':ts,'cwd':'/work/app','requestId':'r'+mid,'message':{'id':mid,'model':'m','usage':{'input_tokens':1,'output_tokens':out}}})
        (folder/'s.jsonl').write_text('\n'.join([line('a','2026-10-01T15:00:00Z',5),line('a','2026-10-01T15:00:00Z',5),line('b','2026-10-01T17:30:00Z',7)])+'\n')
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'s.jsonl').stat().st_mtime):
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['project'],r['input'],r['output']) for r in result['projects']],[('/work/app',2,12)])
        self.assertEqual(len(result['activity']),1)
        self.assertEqual(sum(result['activity'][0]['hours']),2)
        # A live session appends: only new bytes are read, a response split across the seam
        # counts once, and a half-written last line waits for the next scan.
        with open(folder/'s.jsonl','a') as stream:
            stream.write(line('b','2026-10-01T17:30:00Z',7)+'\n'+line('c','2026-10-01T18:00:00Z',9)+'\n'+line('d','2026-10-01T18:05:00Z',100)[:30])
        with patch.object(Path,'home',return_value=Path(self.temp.name)/'home'), patch.object(bridge.time,'time',return_value=(folder/'s.jsonl').stat().st_mtime), \
             patch.object(bridge,'json',wraps=json) as spy:
            result=bridge.report(self.root,days=10000)
        self.assertEqual([(r['input'],r['output']) for r in result['projects']],[(3,21)])
        self.assertEqual(sum(1 for c in spy.loads.call_args_list if 'usage' in str(c)),2)

if __name__ == '__main__': unittest.main()
