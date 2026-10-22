#region Copyright & License Information
/*
 * Copyright (c) The OpenRA Developers and Contributors
 * This file is part of OpenRA, which is free software. It is made
 * available to you under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version 3 of
 * the License, or (at your option) any later version. For more
 * information, see COPYING.
 */
#endregion

using System.Collections.Generic;
using System.Linq;
using OpenRA.Mods.Common.Orders;
using OpenRA.Mods.Common.Traits;
using OpenRA.Orders;
using OpenRA.Traits;
using OpenRA.Widgets;

namespace OpenRA.Mods.Common.Widgets.Logic
{
	public abstract class ChromeOrderButtonLogic<T> : ChromeLogic where T : IOrderGenerator
	{
		protected ChromeOrderButtonLogic(Widget w, World world, string icon)
		{
			if (w is not ButtonWidget widget)
				return;

			widget.OnClick = () =>
			{
				if (world.OrderGenerator is T)
					world.CancelInputMode();
				else
					world.OrderGenerator = (IOrderGenerator)typeof(T).GetConstructor([typeof(World)])?.Invoke([world]);
			};

			widget.IsHighlighted = () => world.OrderGenerator is T;

			widget.Get<ImageWidget>("ICON").GetImageName =
				() => world.OrderGenerator is T ? icon + "-active" : icon;
		}
	}

	[method: ObjectCreator.UseCtor]
	public class SellOrderButtonLogic(Widget widget, World world)
		: ChromeOrderButtonLogic<SellOrderGenerator>(widget, world, "sell");

	[method: ObjectCreator.UseCtor]
	public class RepairOrderButtonLogic(Widget widget, World world)
		: ChromeOrderButtonLogic<RepairOrderGenerator>(widget, world, "repair");

	public class RepairAllOrderButtonLogic : ChromeLogic
	{
		[ObjectCreator.UseCtor]
		public RepairAllOrderButtonLogic(Widget widget, World world)
		{
			if (widget is not ButtonWidget button)
				return;

			// Start repairs on every damaged building that is not repaired yet; when there is nothing left to start,
			// a click stops the repairs instead. Only the first order announces it, so a big base is not noisy.
			button.OnClick = () =>
			{
				var buildings = DamagedBuildings(world).ToList();
				if (buildings.Count == 0)
					buildings = RepairedBuildings(world).ToList();

				for (var i = 0; i < buildings.Count; i++)
				{
					world.IssueOrder(new Order("RepairBuilding", world.LocalPlayer.PlayerActor, Target.FromActor(buildings[i]), false)
					{
						ExtraData = i == 0 ? 0u : AllyRepair.SilentExtraData,
					});
				}
			};

			// Lit up (like the Repair button in repair mode) for as long as any of our buildings is being repaired.
			// The button asks every frame, so only scan the world once per tick.
			var checkedTick = -1;
			var repairing = false;
			button.IsHighlighted = () =>
			{
				if (checkedTick != world.WorldTick)
				{
					checkedTick = world.WorldTick;
					repairing = RepairedBuildings(world).Any();
				}

				return repairing;
			};

			button.Get<ImageWidget>("ICON").GetImageName =
				() => button.IsHighlighted() ? "repair-all-active" : "repair-all";
		}

		static IEnumerable<TraitPair<RepairableBuilding>> OwnBuildings(World world)
		{
			if (world.LocalPlayer == null || world.LocalPlayer.Spectating)
				return [];

			return world.ActorsWithTrait<RepairableBuilding>()
				.Where(tp => tp.Actor.Owner == world.LocalPlayer && !tp.Actor.IsDead);
		}

		static IEnumerable<Actor> RepairedBuildings(World world)
		{
			return OwnBuildings(world)
				.Where(tp => tp.Trait.Repairers.Contains(world.LocalPlayer))
				.Select(tp => tp.Actor);
		}

		// RepairBuilding toggles, so only pick buildings the local player is not repairing yet.
		static IEnumerable<Actor> DamagedBuildings(World world)
		{
			return OwnBuildings(world)
				.Where(tp => !tp.Trait.IsTraitDisabled
					&& !tp.Trait.Repairers.Contains(world.LocalPlayer)
					&& tp.Actor.GetDamageState() is > DamageState.Undamaged and < DamageState.Dead)
				.Select(tp => tp.Actor);
		}
	}

	[method: ObjectCreator.UseCtor]
	public class PowerdownOrderButtonLogic(Widget widget, World world)
		: ChromeOrderButtonLogic<PowerDownOrderGenerator>(widget, world, "power");

	[method: ObjectCreator.UseCtor]
	public class BeaconOrderButtonLogic(Widget widget, World world)
		: ChromeOrderButtonLogic<BeaconOrderGenerator>(widget, world, "beacon");
}
